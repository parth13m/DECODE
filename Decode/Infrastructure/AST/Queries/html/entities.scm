; HTML entity extraction queries for Decode Session Mode.
; Captures: @name (tag name), @definition (full element node)
;
; HTML does not have functions/classes. Instead we extract semantic
; structural elements that represent meaningful sections of a page.

; --- All elements (tag_name serves as the entity name) ---
; The TreeSitterParser will filter to semantic elements post-extraction.

(element
  (start_tag
    (tag_name) @name)) @definition

; --- Self-closing tags ---

(self_closing_tag
  (tag_name) @name) @definition

; --- Script elements ---

(script_element
  (start_tag
    (tag_name) @name)) @definition

; --- Style elements ---

(style_element
  (start_tag
    (tag_name) @name)) @definition
