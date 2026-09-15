; extends

((comment) @jupyter.markdown.text
  (#jupyter-markdown-cell? @jupyter.markdown.text)
  (#jupyter-md-comment-range! @jupyter.markdown.text))
