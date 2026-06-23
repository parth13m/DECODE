; Python call extraction queries for Decode.
; Captures: @call (full call expression), @callee (function name or attribute)

; --- Direct function calls: foo() ---

(call
  function: (identifier) @callee) @call

; --- Method/attribute calls: obj.method() ---

(call
  function: (attribute) @callee) @call
