; C# call extraction queries for Decode.
; Captures: @call (full invocation expression)

; --- Method invocations: obj.Method(), this.Method(), Method() ---

(invocation_expression) @call

; --- Constructor calls: new MyClass() ---

(object_creation_expression) @call
