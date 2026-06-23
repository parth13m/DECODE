; JavaScript import extraction queries for Decode.
; Captures: @import (full import statement node)

; --- import declarations ---

(import_statement) @import

; --- require() calls assigned to variables ---
; e.g., const X = require('module')

(lexical_declaration
  (variable_declarator
    value: (call_expression
      function: (identifier) @_fn
      (#eq? @_fn "require")))) @import

(variable_declaration
  (variable_declarator
    value: (call_expression
      function: (identifier) @_fn
      (#eq? @_fn "require")))) @import
