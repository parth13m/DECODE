; C# entity extraction queries for Decode Session Mode.
; Captures: @name (entity name), @definition (full node)

; --- Class declarations ---

(class_declaration
  name: (identifier) @name) @definition

; --- Interface declarations ---

(interface_declaration
  name: (identifier) @name) @definition

; --- Struct declarations ---

(struct_declaration
  name: (identifier) @name) @definition

; --- Enum declarations ---

(enum_declaration
  name: (identifier) @name) @definition

; --- Method declarations ---

(method_declaration
  name: (identifier) @name) @definition

; --- Constructor declarations ---

(constructor_declaration
  name: (identifier) @name) @definition

; --- Namespace declarations ---

(namespace_declaration
  name: (identifier) @name) @definition

; --- Record declarations ---

(record_declaration
  name: (identifier) @name) @definition
