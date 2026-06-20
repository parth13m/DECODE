; Python entity extraction queries for Decode Session Mode.
; Captures: @name (entity name), @definition (full node), @entity_type (type hint)

; --- Functions (top-level and nested) ---

(function_definition
  name: (identifier) @name) @definition

; --- Classes ---

(class_definition
  name: (identifier) @name) @definition

; --- Decorated definitions (functions and classes with decorators) ---

(decorated_definition
  definition: (function_definition
    name: (identifier) @name)) @definition

(decorated_definition
  definition: (class_definition
    name: (identifier) @name)) @definition
