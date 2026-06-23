; C++ call extraction queries for Decode.
; Captures: @call (full call expression), @callee (function name or member expression)

; --- Direct function calls: foo() ---

(call_expression
  function: (identifier) @callee) @call

; --- Method calls: obj.method(), ptr->method() ---

(call_expression
  function: (field_expression) @callee) @call

; --- Qualified calls: Namespace::func(), Type::staticMethod() ---

(call_expression
  function: (qualified_identifier) @callee) @call
