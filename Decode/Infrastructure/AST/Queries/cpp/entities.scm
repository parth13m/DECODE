; C++ entity extraction queries for Decode Session Mode.
; Captures: @name (entity name), @definition (full node)

; --- Function definitions ---

(function_definition
  declarator: (function_declarator
    declarator: (identifier) @name)) @definition

; --- Qualified function definitions (Class::method) ---

(function_definition
  declarator: (function_declarator
    declarator: (qualified_identifier
      name: (identifier) @name))) @definition

; --- Class definitions ---

(class_specifier
  name: (type_identifier) @name) @definition

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

; --- Namespace definitions ---

(namespace_definition
  name: (namespace_identifier) @name) @definition

; --- Template declarations (wrapping function/class) ---
; Template declarations wrap other definitions, so the inner
; function/class patterns above will match their contents.
