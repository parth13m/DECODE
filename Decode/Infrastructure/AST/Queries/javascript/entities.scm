; JavaScript entity extraction queries for Decode Session Mode.
; Captures: @name (entity name), @definition (full node)

; --- Function declarations ---

(function_declaration
  name: (identifier) @name) @definition

; --- Generator function declarations ---

(generator_function_declaration
  name: (identifier) @name) @definition

; --- Class declarations ---

(class_declaration
  name: (identifier) @name) @definition

; --- Class expressions with name ---

(class
  name: (identifier) @name) @definition

; --- Arrow functions / function expressions assigned to const/let/var ---

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

; --- Exported function/class declarations ---

(export_statement
  (function_declaration
    name: (identifier) @name)) @definition

(export_statement
  (class_declaration
    name: (identifier) @name)) @definition

(export_statement
  (lexical_declaration
    (variable_declarator
      name: (identifier) @name
      value: [(arrow_function) (function_expression)]))) @definition
