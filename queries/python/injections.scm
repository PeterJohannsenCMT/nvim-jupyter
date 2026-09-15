; extends

((comment) @injection.content
  (#jupyter-markdown-cell? @injection.content)
  (#jupyter-md-comment-range! @injection.content)
  (#set! injection.language "markdown")
  (#set! injection.combined))
