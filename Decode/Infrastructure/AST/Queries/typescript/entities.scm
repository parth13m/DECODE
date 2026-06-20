; TypeScript entity extraction queries for Decode Session Mode.
; Captures: @name (entity name), @definition (full node)
;
; NOTE: The TypeScript grammar extends JavaScript, so many JS patterns
; also work here. This file adds TypeScript-specific constructs.

; --- Function declarations ---

(function_declaration
  name: (identifier) @name) @definition

; --- Class declarations ---

(class_declaration
  name: (type_identifier) @name) @definition

; --- Abstract class declarations ---

(abstract_class_declaration
  name: (type_identifier) @name) @definition

; --- Interface declarations ---

(interface_declaration
  name: (type_identifier) @name) @definition

; --- Enum declarations ---

(enum_declaration
  name: (identifier) @name) @definition

; --- Type alias declarations ---

(type_alias_declaration
  name: (type_identifier) @name) @definition

; --- Arrow functions / function expressions assigned to const/let ---

(lexical_declaration
  (variable_declarator
    name: (identifier) @name
    value: [(arrow_function) (function_expression)])) @definition

(variable_declaration
  (variable_declarator
    name: (identifier) @name
    value: [(arrow_function) (function_expression)])) @definition

; --- Method definitions (inside classes) ---

(method_definition
  name: (property_identifier) @name) @definition

; --- Method signatures (in interfaces) ---

(method_signature
  name: (property_identifier) @name) @definition

; --- Abstract method signatures ---

(abstract_method_signature
  name: (property_identifier) @name) @definition

; --- Function signatures (ambient declarations) ---

(function_signature
  name: (identifier) @name) @definition

; --- Exported declarations ---

(export_statement
  (function_declaration
    name: (identifier) @name)) @definition

(export_statement
  (class_declaration
    name: (type_identifier) @name)) @definition

(export_statement
  (interface_declaration
    name: (type_identifier) @name)) @definition

(export_statement
  (enum_declaration
    name: (identifier) @name)) @definition

(export_statement
  (type_alias_declaration
    name: (type_identifier) @name)) @definition

(export_statement
  (lexical_declaration
    (variable_declarator
      name: (identifier) @name
      value: [(arrow_function) (function_expression)]))) @definition
