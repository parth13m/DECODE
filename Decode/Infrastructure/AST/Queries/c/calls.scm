; C call extraction queries for Decode.
; Captures: @call (full call expression), @callee (function name)

; --- Direct function calls: foo() ---

(call_expression
  function: (identifier) @callee) @call

; --- Function pointer calls via member access: obj->func(), obj.func() ---

(call_expression
  function: (field_expression) @callee) @call
