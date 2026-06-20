; CSS entity extraction queries for Decode Session Mode.
; Captures: @name (selector/name), @definition (full rule node)

; --- Rule sets (selector { ... }) ---
; The selectors node contains the full selector text.

(rule_set
  (selectors) @name) @definition

; --- Media queries (@media ...) ---

(media_statement) @definition

; --- Keyframe animations (@keyframes name { ... }) ---

(keyframes_statement
  (keyframes_name) @name) @definition

; --- Supports queries (@supports ...) ---

(supports_statement) @definition

; --- Charset statements ---

(charset_statement) @definition

; --- Import statements ---

(import_statement) @definition
