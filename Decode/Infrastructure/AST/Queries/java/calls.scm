; Java call extraction queries for Decode.
; Captures: @call (full call expression), @callee (method name or identifier)

; --- Method invocations: obj.method(), this.method() ---

(method_invocation) @call

; --- Constructor calls: new MyClass() ---

(object_creation_expression) @call
