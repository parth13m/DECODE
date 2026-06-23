; TypeScript call extraction queries for Decode.
; Captures: @call (full call expression), @callee (function name or member expression)

; --- Direct function calls: foo() ---

(call_expression
  function: (identifier) @callee) @call

; --- Method calls: obj.method() ---

(call_expression
  function: (member_expression) @callee) @call
