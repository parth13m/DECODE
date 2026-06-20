; C entity extraction queries for Decode Session Mode.
; Captures: @name (entity name), @definition (full node)

; --- Function definitions ---

(function_definition
  declarator: (function_declarator
    declarator: (identifier) @name)) @definition

; --- Struct definitions (with body) ---

(struct_specifier
  name: (type_identifier) @name
  body: (_)) @definition

; --- Enum definitions ---

(enum_specifier
  name: (type_identifier) @name) @definition

; --- Typedef declarations ---

(type_definition
  declarator: (type_identifier) @name) @definition

; --- Union definitions ---

(union_specifier
  name: (type_identifier) @name
  body: (_)) @definition
