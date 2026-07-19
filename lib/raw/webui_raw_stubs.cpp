#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>
#include <vector>

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/custom.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include "webview/webview.h"

namespace {

enum lifecycle_state {
  STATE_CREATED = 0,
  STATE_RUNNING = 1,
  STATE_CLOSING = 2,
  STATE_STOPPED = 3,
  STATE_DESTROYED = 4,
};

struct dispatch_item {
  value callbacks;
};

struct window_context;

struct binding_context {
  window_context *window;
  std::string name;
  std::uint64_t token;
  value handler;
  bool active;
  unsigned int callbacks_in_flight;
};

struct pending_call_context {
  std::string binding_name;
  std::string id;
  value cancel;
};

struct window_context {
  webview_t handle;
  std::atomic<int> state;
  DWORD owner_thread_id;
  std::mutex dispatch_mutex;
  std::deque<dispatch_item *> dispatch_queue;
  bool dispatch_wakeup_scheduled;
  std::uint64_t dispatch_roots;
  std::uint64_t dispatch_enqueued;
  std::uint64_t dispatch_executed;
  std::uint64_t dispatch_cancelled;
  std::uint64_t callback_exceptions;
  bool fail_next_dispatch;
  bool binding_mutation_in_progress;
  std::unordered_map<std::string, binding_context *> bindings;
  std::unordered_map<std::string, pending_call_context *> pending_calls;
  std::uint64_t binding_roots;
  std::uint64_t next_binding_token;

  explicit window_context(webview_t native_handle)
      : handle(native_handle), state(STATE_CREATED),
        owner_thread_id(GetCurrentThreadId()), dispatch_wakeup_scheduled(false),
        dispatch_roots(0), dispatch_enqueued(0), dispatch_executed(0),
        dispatch_cancelled(0), callback_exceptions(0),
        fail_next_dispatch(false), binding_mutation_in_progress(false),
        binding_roots(0), next_binding_token(1) {}
};

static window_context **context_slot(value vwindow) {
  return reinterpret_cast<window_context **>(Data_custom_val(vwindow));
}

static window_context *context_of_value(value vwindow) {
  return *context_slot(vwindow);
}

static void finalize_window(value vwindow) {
  window_context **slot = context_slot(vwindow);
  window_context *context = *slot;
  if (context == nullptr) {
    return;
  }
  // Never call WebView APIs from a GC finalizer: it may run on the wrong
  // Domain/thread. A live context is intentionally retained as a detectable
  // lifecycle leak. An explicitly destroyed context is inert and safe to free.
  if (context->state.load(std::memory_order_acquire) == STATE_DESTROYED &&
      context->handle == nullptr) {
    delete context;
  }
  *slot = nullptr;
}

static struct custom_operations window_operations = {
    "ocaml-webui.raw.window.v1",
    finalize_window,
    custom_compare_default,
    custom_hash_default,
    custom_serialize_default,
    custom_deserialize_default,
    custom_compare_ext_default,
    custom_fixed_length_default,
};

static const char *error_message(webview_error_t error) {
  switch (error) {
  case WEBVIEW_ERROR_MISSING_DEPENDENCY:
    return "missing dependency";
  case WEBVIEW_ERROR_CANCELED:
    return "operation cancelled";
  case WEBVIEW_ERROR_INVALID_STATE:
    return "invalid state";
  case WEBVIEW_ERROR_INVALID_ARGUMENT:
    return "invalid argument";
  case WEBVIEW_ERROR_UNSPECIFIED:
    return "unspecified error";
  case WEBVIEW_ERROR_OK:
    return "ok";
  case WEBVIEW_ERROR_DUPLICATE:
    return "already exists";
  case WEBVIEW_ERROR_NOT_FOUND:
    return "not found";
  default:
    return "unknown native error";
  }
}

static value alloc_error_option(int code, const char *message) {
  CAMLparam0();
  CAMLlocal3(verror, vmessage, vsome);
  verror = caml_alloc_tuple(2);
  Store_field(verror, 0, Val_int(code));
  vmessage = caml_copy_string(message);
  Store_field(verror, 1, vmessage);
  vsome = caml_alloc(1, 0);
  Store_field(vsome, 0, verror);
  CAMLreturn(vsome);
}

static value alloc_native_error(webview_error_t error) {
  if (error == WEBVIEW_ERROR_OK) {
    return Val_none;
  }
  return alloc_error_option(static_cast<int>(error), error_message(error));
}

static value alloc_invalid_state(const char *message) {
  return alloc_error_option(static_cast<int>(WEBVIEW_ERROR_INVALID_STATE),
                            message);
}

static value alloc_bind_error(webview_error_t error, const char *message) {
  CAMLparam0();
  CAMLlocal2(vresult, vmessage);
  vresult = caml_alloc(2, 1); // Bind_error of int * string
  Store_field(vresult, 0, Val_int(static_cast<int>(error)));
  vmessage = caml_copy_string(message);
  Store_field(vresult, 1, vmessage);
  CAMLreturn(vresult);
}

static value alloc_bound(std::uint64_t token) {
  CAMLparam0();
  CAMLlocal1(vresult);
  vresult = caml_alloc(1, 0); // Bound of int
  Store_field(vresult, 0, Val_long(token));
  CAMLreturn(vresult);
}

static bool is_owner_thread(window_context *context) {
  return GetCurrentThreadId() == context->owner_thread_id;
}

static bool configuration_allowed(int state) {
  return state == STATE_CREATED || state == STATE_RUNNING;
}

static webview_hint_t hint_of_int(int hint) {
  switch (hint) {
  case 1:
    return WEBVIEW_HINT_MIN;
  case 2:
    return WEBVIEW_HINT_MAX;
  case 3:
    return WEBVIEW_HINT_FIXED;
  default:
    return WEBVIEW_HINT_NONE;
  }
}

static void release_dispatch_item(dispatch_item *item) {
  caml_remove_generational_global_root(&item->callbacks);
  delete item;
}

static std::deque<dispatch_item *>
take_queued_dispatches(window_context *context, bool cancelled) {
  std::deque<dispatch_item *> items;
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    items.swap(context->dispatch_queue);
    context->dispatch_wakeup_scheduled = false;
    if (cancelled) {
      context->dispatch_cancelled += items.size();
    }
  }
  return items;
}

static void cancel_dispatches(window_context *context,
                              std::deque<dispatch_item *> &items) {
  const std::uint64_t cancelled = items.size();
  std::uint64_t exceptions = 0;
  for (dispatch_item *item : items) {
    value result = caml_callback_exn(Field(item->callbacks, 1), Val_unit);
    if (Is_exception_result(result)) {
      ++exceptions;
    }
    release_dispatch_item(item);
  }
  items.clear();
  if (cancelled > 0 || exceptions > 0) {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    context->dispatch_roots -= cancelled;
    context->callback_exceptions += exceptions;
  }
}

static void release_binding(binding_context *binding) {
  caml_remove_generational_global_root(&binding->handler);
  if (binding->callbacks_in_flight == 0) {
    delete binding;
  }
}

static void cancel_pending_calls(
    window_context *context,
    std::vector<pending_call_context *> &pending_calls) {
  std::uint64_t exceptions = 0;
  for (pending_call_context *pending : pending_calls) {
    value result = caml_callback_exn(pending->cancel, Val_unit);
    if (Is_exception_result(result)) {
      ++exceptions;
    }
    caml_remove_generational_global_root(&pending->cancel);
    delete pending;
  }
  pending_calls.clear();
  if (exceptions > 0) {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    context->callback_exceptions += exceptions;
  }
}

static void binding_callback(const char *id, const char *request,
                             void *argument) {
  binding_context *binding = static_cast<binding_context *>(argument);
  window_context *context = binding->window;
  caml_acquire_runtime_system();
  CAMLparam0();
  CAMLlocal4(vhandler, vid, vrequest, vresult);

  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    ++binding->callbacks_in_flight;
    vhandler = binding->handler;
  }
  vid = caml_copy_string(id);
  vrequest = caml_copy_string(request);
  vresult = caml_callback2_exn(vhandler, vid, vrequest);
  const bool raised = Is_exception_result(vresult);
  bool delete_after_callback = false;
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    if (raised) {
      ++context->callback_exceptions;
    }
    --binding->callbacks_in_flight;
    delete_after_callback =
        !binding->active && binding->callbacks_in_flight == 0;
  }

  CAMLdrop;
  if (raised) {
    // The OCaml wrapper normally converts handler exceptions into a rejected
    // Call. This is a final defensive response for exceptions in that wrapper.
    webview_return(context->handle, id, 1, "\"binding callback raised\"");
  }
  if (delete_after_callback) {
    delete binding;
  }
  caml_release_runtime_system();
}

static void drain_dispatch_queue(webview_t, void *argument) {
  window_context *context = static_cast<window_context *>(argument);
  caml_acquire_runtime_system();

  std::deque<dispatch_item *> items;
  bool cancelled = false;
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    cancelled =
        context->state.load(std::memory_order_acquire) != STATE_RUNNING;
    items.swap(context->dispatch_queue);
    context->dispatch_wakeup_scheduled = false;
    if (cancelled) {
      context->dispatch_cancelled += items.size();
    }
  }

  if (cancelled) {
    cancel_dispatches(context, items);
    caml_release_runtime_system();
    return;
  }

  std::uint64_t executed = 0;
  std::uint64_t exceptions = 0;
  for (dispatch_item *item : items) {
    value result = caml_callback_exn(Field(item->callbacks, 0), Val_unit);
    ++executed;
    if (Is_exception_result(result)) {
      ++exceptions;
    }
    release_dispatch_item(item);
  }
  items.clear();

  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    context->dispatch_roots -= executed;
    context->dispatch_executed += executed;
    context->callback_exceptions += exceptions;
  }
  caml_release_runtime_system();
}

static void terminate_on_ui_thread(webview_t window, void *) {
  // webview 0.12 documents terminate as background-thread safe, but its Win32
  // implementation calls PostQuitMessage, which targets the calling thread.
  // Enter through webview_dispatch so termination runs on the UI event loop.
  webview_terminate(window);
}

} // namespace

extern "C" {

CAMLprim value ocaml_webui_raw_create(value vdebug) {
  CAMLparam1(vdebug);
  CAMLlocal2(vwindow, vresult);

  webview_t handle = webview_create(Bool_val(vdebug), nullptr);
  if (handle == nullptr) {
    vresult = caml_alloc(2, 1); // Create_error of int * string
    Store_field(vresult, 0, Val_int(WEBVIEW_ERROR_UNSPECIFIED));
    Store_field(vresult, 1, caml_copy_string("webview_create returned null"));
    CAMLreturn(vresult);
  }

  window_context *context = new (std::nothrow) window_context(handle);
  if (context == nullptr) {
    webview_destroy(handle);
    vresult = caml_alloc(2, 1);
    Store_field(vresult, 0, Val_int(WEBVIEW_ERROR_UNSPECIFIED));
    Store_field(vresult, 1,
                caml_copy_string("unable to allocate native window context"));
    CAMLreturn(vresult);
  }

  vwindow = caml_alloc_custom(&window_operations, sizeof(window_context *), 0, 1);
  *context_slot(vwindow) = context;
  vresult = caml_alloc(1, 0); // Created of window
  Store_field(vresult, 0, vwindow);
  CAMLreturn(vresult);
}

CAMLprim value ocaml_webui_raw_state(value vwindow) {
  CAMLparam1(vwindow);
  window_context *context = context_of_value(vwindow);
  CAMLreturn(Val_int(context->state.load(std::memory_order_acquire)));
}

CAMLprim value ocaml_webui_raw_run(value vwindow) {
  CAMLparam1(vwindow);
  window_context *context = context_of_value(vwindow);
  if (!is_owner_thread(context)) {
    CAMLreturn(alloc_invalid_state("run must execute on the owner thread"));
  }

  int expected = STATE_CREATED;
  if (!context->state.compare_exchange_strong(
          expected, STATE_RUNNING, std::memory_order_acq_rel)) {
    CAMLreturn(alloc_invalid_state("run requires the Created state"));
  }

  caml_release_runtime_system();
  webview_error_t error = webview_run(context->handle);
  caml_acquire_runtime_system();
  std::deque<dispatch_item *> cancelled;
  std::vector<pending_call_context *> pending_calls;
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    cancelled.swap(context->dispatch_queue);
    context->dispatch_wakeup_scheduled = false;
    context->dispatch_cancelled += cancelled.size();
    for (auto &entry : context->pending_calls) {
      pending_calls.push_back(entry.second);
    }
    context->pending_calls.clear();
    context->state.store(STATE_STOPPED, std::memory_order_release);
  }
  cancel_pending_calls(context, pending_calls);
  cancel_dispatches(context, cancelled);
  CAMLreturn(alloc_native_error(error));
}

CAMLprim value ocaml_webui_raw_request_close(value vwindow) {
  CAMLparam1(vwindow);
  window_context *context = context_of_value(vwindow);

  std::deque<dispatch_item *> cancelled;
  std::vector<pending_call_context *> pending_calls;
  webview_error_t error = WEBVIEW_ERROR_OK;
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    int expected = STATE_RUNNING;
    if (!context->state.compare_exchange_strong(
            expected, STATE_CLOSING, std::memory_order_acq_rel)) {
      if (expected == STATE_CLOSING) {
        CAMLreturn(Val_none);
      }
      CAMLreturn(
          alloc_invalid_state("request_close requires Running or Closing"));
    }
    cancelled.swap(context->dispatch_queue);
    context->dispatch_wakeup_scheduled = false;
    context->dispatch_cancelled += cancelled.size();
    for (auto &entry : context->pending_calls) {
      pending_calls.push_back(entry.second);
    }
    context->pending_calls.clear();
    // The scheduling call is asynchronous on supported backends. Keep it
    // serialized with queue acceptance and the transition to Stopped so the
    // native handle cannot be destroyed while scheduling is in flight.
    error = webview_dispatch(context->handle, terminate_on_ui_thread, context);
    if (error != WEBVIEW_ERROR_OK) {
      int expected = STATE_CLOSING;
      context->state.compare_exchange_strong(expected, STATE_RUNNING,
                                             std::memory_order_acq_rel);
    }
  }
  cancel_pending_calls(context, pending_calls);
  cancel_dispatches(context, cancelled);
  CAMLreturn(alloc_native_error(error));
}

CAMLprim value ocaml_webui_raw_destroy(value vwindow) {
  CAMLparam1(vwindow);
  window_context *context = context_of_value(vwindow);
  if (!is_owner_thread(context)) {
    CAMLreturn(alloc_invalid_state("destroy must execute on the owner thread"));
  }

  int state = context->state.load(std::memory_order_acquire);
  if (state == STATE_DESTROYED) {
    CAMLreturn(Val_none);
  }
  if (state != STATE_CREATED && state != STATE_STOPPED) {
    CAMLreturn(alloc_invalid_state("destroy requires Created or Stopped"));
  }

  webview_error_t error = webview_destroy(context->handle);
  if (error == WEBVIEW_ERROR_OK) {
    std::vector<binding_context *> bindings;
    std::vector<pending_call_context *> pending_calls;
    {
      std::lock_guard<std::mutex> lock(context->dispatch_mutex);
      for (auto &entry : context->bindings) {
        entry.second->active = false;
        bindings.push_back(entry.second);
      }
      context->bindings.clear();
      context->binding_roots = 0;
      for (auto &entry : context->pending_calls) {
        pending_calls.push_back(entry.second);
      }
      context->pending_calls.clear();
    }
    for (binding_context *binding : bindings) {
      release_binding(binding);
    }
    cancel_pending_calls(context, pending_calls);
    std::deque<dispatch_item *> cancelled =
        take_queued_dispatches(context, true);
    cancel_dispatches(context, cancelled);
    {
      std::lock_guard<std::mutex> lock(context->dispatch_mutex);
      context->handle = nullptr;
      context->state.store(STATE_DESTROYED, std::memory_order_release);
    }
  }
  CAMLreturn(alloc_native_error(error));
}

CAMLprim value ocaml_webui_raw_set_title(value vwindow, value vtitle) {
  CAMLparam2(vwindow, vtitle);
  window_context *context = context_of_value(vwindow);
  if (!is_owner_thread(context)) {
    CAMLreturn(alloc_invalid_state("set_title requires the owner thread"));
  }
  if (!configuration_allowed(context->state.load(std::memory_order_acquire))) {
    CAMLreturn(alloc_invalid_state("set_title requires Created or Running"));
  }
  CAMLreturn(alloc_native_error(
      webview_set_title(context->handle, String_val(vtitle))));
}

CAMLprim value ocaml_webui_raw_set_size(value vwindow, value vwidth,
                                        value vheight, value vhint) {
  CAMLparam4(vwindow, vwidth, vheight, vhint);
  window_context *context = context_of_value(vwindow);
  if (!is_owner_thread(context)) {
    CAMLreturn(alloc_invalid_state("set_size requires the owner thread"));
  }
  if (!configuration_allowed(context->state.load(std::memory_order_acquire))) {
    CAMLreturn(alloc_invalid_state("set_size requires Created or Running"));
  }
  CAMLreturn(alloc_native_error(webview_set_size(
      context->handle, Int_val(vwidth), Int_val(vheight),
      hint_of_int(Int_val(vhint)))));
}

CAMLprim value ocaml_webui_raw_navigate(value vwindow, value vurl) {
  CAMLparam2(vwindow, vurl);
  window_context *context = context_of_value(vwindow);
  if (!is_owner_thread(context)) {
    CAMLreturn(alloc_invalid_state("navigate requires the owner thread"));
  }
  if (!configuration_allowed(context->state.load(std::memory_order_acquire))) {
    CAMLreturn(alloc_invalid_state("navigate requires Created or Running"));
  }
  CAMLreturn(
      alloc_native_error(webview_navigate(context->handle, String_val(vurl))));
}

CAMLprim value ocaml_webui_raw_set_html(value vwindow, value vhtml) {
  CAMLparam2(vwindow, vhtml);
  window_context *context = context_of_value(vwindow);
  if (!is_owner_thread(context)) {
    CAMLreturn(alloc_invalid_state("set_html requires the owner thread"));
  }
  if (!configuration_allowed(context->state.load(std::memory_order_acquire))) {
    CAMLreturn(alloc_invalid_state("set_html requires Created or Running"));
  }
  CAMLreturn(
      alloc_native_error(webview_set_html(context->handle, String_val(vhtml))));
}

CAMLprim value ocaml_webui_raw_init(value vwindow, value vjs) {
  CAMLparam2(vwindow, vjs);
  window_context *context = context_of_value(vwindow);
  if (!is_owner_thread(context)) {
    CAMLreturn(alloc_invalid_state("init requires the owner thread"));
  }
  if (!configuration_allowed(context->state.load(std::memory_order_acquire))) {
    CAMLreturn(alloc_invalid_state("init requires Created or Running"));
  }
  CAMLreturn(alloc_native_error(webview_init(context->handle, String_val(vjs))));
}

CAMLprim value ocaml_webui_raw_eval(value vwindow, value vjs) {
  CAMLparam2(vwindow, vjs);
  window_context *context = context_of_value(vwindow);
  if (!is_owner_thread(context)) {
    CAMLreturn(alloc_invalid_state("eval requires the owner thread"));
  }
  if (!configuration_allowed(context->state.load(std::memory_order_acquire))) {
    CAMLreturn(alloc_invalid_state("eval requires Created or Running"));
  }
  CAMLreturn(alloc_native_error(webview_eval(context->handle, String_val(vjs))));
}

CAMLprim value ocaml_webui_raw_dispatch(value vwindow, value vcallback,
                                        value vcancel) {
  CAMLparam3(vwindow, vcallback, vcancel);
  CAMLlocal1(vcallbacks);
  window_context *context = context_of_value(vwindow);
  vcallbacks = caml_alloc_tuple(2);
  Store_field(vcallbacks, 0, vcallback);
  Store_field(vcallbacks, 1, vcancel);
  dispatch_item *item = new (std::nothrow) dispatch_item{vcallbacks};
  if (item == nullptr) {
    CAMLreturn(alloc_error_option(
        static_cast<int>(WEBVIEW_ERROR_UNSPECIFIED),
        "unable to allocate dispatch queue item"));
  }
  caml_register_generational_global_root(&item->callbacks);

  webview_error_t error = WEBVIEW_ERROR_OK;
  std::deque<dispatch_item *> cancelled;
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    if (context->state.load(std::memory_order_acquire) != STATE_RUNNING) {
      release_dispatch_item(item);
      CAMLreturn(alloc_invalid_state("dispatch requires the Running state"));
    }
    context->dispatch_queue.push_back(item);
    ++context->dispatch_roots;
    ++context->dispatch_enqueued;
    if (!context->dispatch_wakeup_scheduled) {
      context->dispatch_wakeup_scheduled = true;
      // webview_dispatch only schedules the callback. Serializing this short
      // native call closes the accept/schedule/destroy race without holding
      // the mutex while any OCaml callback executes.
      if (context->fail_next_dispatch) {
        context->fail_next_dispatch = false;
        error = WEBVIEW_ERROR_UNSPECIFIED;
      } else {
        error =
            webview_dispatch(context->handle, drain_dispatch_queue, context);
      }
      if (error != WEBVIEW_ERROR_OK) {
        cancelled.swap(context->dispatch_queue);
        context->dispatch_wakeup_scheduled = false;
        context->dispatch_cancelled += cancelled.size();
      }
    }
  }
  cancel_dispatches(context, cancelled);
  CAMLreturn(alloc_native_error(error));
}

CAMLprim value ocaml_webui_raw_bind(value vwindow, value vname,
                                    value vhandler) {
  CAMLparam3(vwindow, vname, vhandler);
  window_context *context = context_of_value(vwindow);
  if (!is_owner_thread(context)) {
    CAMLreturn(alloc_bind_error(WEBVIEW_ERROR_INVALID_STATE,
                                "bind requires the owner thread"));
  }

  binding_context *binding = nullptr;
  try {
    binding = new binding_context{context, std::string(String_val(vname)), 0,
                                  vhandler, true, 0};
  } catch (const std::bad_alloc &) {
    CAMLreturn(alloc_bind_error(WEBVIEW_ERROR_UNSPECIFIED,
                                "unable to allocate binding context"));
  }
  caml_register_generational_global_root(&binding->handler);

  webview_error_t error = WEBVIEW_ERROR_OK;
  const char *message = "ok";
  bool registered = false;
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    const int state = context->state.load(std::memory_order_acquire);
    if (!configuration_allowed(state)) {
      error = WEBVIEW_ERROR_INVALID_STATE;
      message = "bind requires Created or Running";
    } else if (context->binding_mutation_in_progress) {
      error = WEBVIEW_ERROR_INVALID_STATE;
      message = "another binding mutation is in progress";
    } else if (context->bindings.find(binding->name) !=
               context->bindings.end()) {
      error = WEBVIEW_ERROR_DUPLICATE;
      message = "binding name already exists";
    } else {
      binding->token = context->next_binding_token++;
      try {
        context->bindings.emplace(binding->name, binding);
      } catch (const std::bad_alloc &) {
        error = WEBVIEW_ERROR_UNSPECIFIED;
        message = "unable to register binding context";
      }
      if (error == WEBVIEW_ERROR_OK) {
        context->binding_mutation_in_progress = true;
        ++context->binding_roots;
        registered = true;
      }
    }
  }

  if (registered) {
    // Win32 AddScriptToExecuteOnDocumentCreated pumps a nested event loop.
    // Release both the context mutex and the OCaml runtime so nested WebView
    // callbacks can safely acquire them.
    caml_release_runtime_system();
    error = webview_bind(context->handle, binding->name.c_str(),
                         binding_callback, binding);
    caml_acquire_runtime_system();
    {
      std::lock_guard<std::mutex> lock(context->dispatch_mutex);
      context->binding_mutation_in_progress = false;
      if (error != WEBVIEW_ERROR_OK) {
        context->bindings.erase(binding->name);
        --context->binding_roots;
        message = error_message(error);
      }
    }
  }

  if (error != WEBVIEW_ERROR_OK) {
    binding->active = false;
    release_binding(binding);
    CAMLreturn(alloc_bind_error(error, message));
  }
  CAMLreturn(alloc_bound(binding->token));
}

CAMLprim value ocaml_webui_raw_unbind(value vwindow, value vname,
                                      value vtoken) {
  CAMLparam3(vwindow, vname, vtoken);
  window_context *context = context_of_value(vwindow);
  if (!is_owner_thread(context)) {
    CAMLreturn(alloc_invalid_state("unbind requires the owner thread"));
  }

  binding_context *binding = nullptr;
  webview_error_t error = WEBVIEW_ERROR_OK;
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    auto iterator = context->bindings.find(String_val(vname));
    if (iterator == context->bindings.end() ||
        iterator->second->token != static_cast<std::uint64_t>(Long_val(vtoken))) {
      CAMLreturn(Val_none);
    }
    binding = iterator->second;
    if (context->binding_mutation_in_progress) {
      CAMLreturn(
          alloc_invalid_state("another binding mutation is in progress"));
    }
    if (binding->callbacks_in_flight > 0) {
      CAMLreturn(alloc_invalid_state(
          "cannot unbind while the binding callback is active; dispatch the removal"));
    }
    for (const auto &entry : context->pending_calls) {
      if (entry.second->binding_name == binding->name) {
        CAMLreturn(alloc_invalid_state(
            "cannot unbind while the binding has pending calls"));
      }
    }
    context->binding_mutation_in_progress = true;
  }

  // webview_unbind replaces the WebView2 startup script and pumps a nested
  // event loop. Nested binding/dispatch callbacks must be able to enter OCaml.
  caml_release_runtime_system();
  error = webview_unbind(context->handle, binding->name.c_str());
  caml_acquire_runtime_system();
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    context->binding_mutation_in_progress = false;
    if (error == WEBVIEW_ERROR_OK) {
      auto iterator = context->bindings.find(binding->name);
      if (iterator != context->bindings.end() &&
          iterator->second == binding) {
        context->bindings.erase(iterator);
      }
      binding->active = false;
      --context->binding_roots;
    }
  }
  if (error == WEBVIEW_ERROR_OK) {
    release_binding(binding);
  }
  CAMLreturn(alloc_native_error(error));
}

CAMLprim value ocaml_webui_raw_register_call(value vwindow,
                                             value vbinding_name, value vid,
                                             value vcancel) {
  CAMLparam4(vwindow, vbinding_name, vid, vcancel);
  window_context *context = context_of_value(vwindow);
  pending_call_context *pending = nullptr;
  try {
    pending = new pending_call_context{std::string(String_val(vbinding_name)),
                                       std::string(String_val(vid)), vcancel};
  } catch (const std::bad_alloc &) {
    CAMLreturn(alloc_error_option(
        static_cast<int>(WEBVIEW_ERROR_UNSPECIFIED),
        "unable to allocate pending call context"));
  }
  caml_register_generational_global_root(&pending->cancel);

  webview_error_t error = WEBVIEW_ERROR_OK;
  const char *message = "ok";
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    if (context->state.load(std::memory_order_acquire) != STATE_RUNNING) {
      error = WEBVIEW_ERROR_INVALID_STATE;
      message = "call registration requires the Running state";
    } else if (context->pending_calls.find(pending->id) !=
               context->pending_calls.end()) {
      error = WEBVIEW_ERROR_DUPLICATE;
      message = "native call ID already exists";
    } else {
      try {
        context->pending_calls.emplace(pending->id, pending);
      } catch (const std::bad_alloc &) {
        error = WEBVIEW_ERROR_UNSPECIFIED;
        message = "unable to register pending call";
      }
    }
  }
  if (error != WEBVIEW_ERROR_OK) {
    caml_remove_generational_global_root(&pending->cancel);
    delete pending;
    CAMLreturn(alloc_error_option(static_cast<int>(error), message));
  }
  CAMLreturn(Val_none);
}

CAMLprim value ocaml_webui_raw_finish_call(value vwindow, value vid) {
  CAMLparam2(vwindow, vid);
  window_context *context = context_of_value(vwindow);
  pending_call_context *pending = nullptr;
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    auto iterator = context->pending_calls.find(String_val(vid));
    if (iterator != context->pending_calls.end()) {
      pending = iterator->second;
      context->pending_calls.erase(iterator);
    }
  }
  if (pending != nullptr) {
    caml_remove_generational_global_root(&pending->cancel);
    delete pending;
  }
  CAMLreturn(Val_unit);
}

CAMLprim value ocaml_webui_raw_return(value vwindow, value vid, value vstatus,
                                      value vresult) {
  CAMLparam4(vwindow, vid, vstatus, vresult);
  window_context *context = context_of_value(vwindow);
  if (!is_owner_thread(context)) {
    CAMLreturn(alloc_invalid_state("respond requires the owner thread"));
  }
  const int state = context->state.load(std::memory_order_acquire);
  if (state != STATE_RUNNING && state != STATE_CLOSING) {
    CAMLreturn(alloc_invalid_state("respond requires Running or Closing"));
  }
  CAMLreturn(alloc_native_error(webview_return(
      context->handle, String_val(vid), Int_val(vstatus), String_val(vresult))));
}

CAMLprim value ocaml_webui_raw_record_callback_exception(value vwindow) {
  CAMLparam1(vwindow);
  window_context *context = context_of_value(vwindow);
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    ++context->callback_exceptions;
  }
  CAMLreturn(Val_unit);
}

CAMLprim value ocaml_webui_raw_fail_next_dispatch(value vwindow) {
  CAMLparam1(vwindow);
  window_context *context = context_of_value(vwindow);
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    context->fail_next_dispatch = true;
  }
  CAMLreturn(Val_unit);
}

CAMLprim value ocaml_webui_raw_diagnostics(value vwindow) {
  CAMLparam1(vwindow);
  CAMLlocal1(vsnapshot);
  window_context *context = context_of_value(vwindow);

  int state;
  std::uint64_t binding_roots;
  std::uint64_t dispatch_roots;
  std::uint64_t pending_calls;
  std::uint64_t queued_dispatches;
  std::uint64_t dispatch_enqueued;
  std::uint64_t dispatch_executed;
  std::uint64_t dispatch_cancelled;
  std::uint64_t callback_exceptions;
  {
    std::lock_guard<std::mutex> lock(context->dispatch_mutex);
    state = context->state.load(std::memory_order_acquire);
    binding_roots = context->binding_roots;
    dispatch_roots = context->dispatch_roots;
    pending_calls = context->pending_calls.size();
    queued_dispatches = context->dispatch_queue.size();
    dispatch_enqueued = context->dispatch_enqueued;
    dispatch_executed = context->dispatch_executed;
    dispatch_cancelled = context->dispatch_cancelled;
    callback_exceptions = context->callback_exceptions;
  }

  vsnapshot = caml_alloc_tuple(9);
  Store_field(vsnapshot, 0, Val_int(state));
  Store_field(vsnapshot, 1, Val_long(binding_roots));
  Store_field(vsnapshot, 2, Val_long(dispatch_roots));
  Store_field(vsnapshot, 3, Val_long(pending_calls));
  Store_field(vsnapshot, 4, Val_long(queued_dispatches));
  Store_field(vsnapshot, 5, Val_long(dispatch_enqueued));
  Store_field(vsnapshot, 6, Val_long(dispatch_executed));
  Store_field(vsnapshot, 7, Val_long(dispatch_cancelled));
  Store_field(vsnapshot, 8, Val_long(callback_exceptions));
  CAMLreturn(vsnapshot);
}

CAMLprim value ocaml_webui_raw_version(value vunit) {
  CAMLparam1(vunit);
  const webview_version_info_t *version = webview_version();
  CAMLreturn(caml_copy_string(version->version_number));
}

} // extern "C"
