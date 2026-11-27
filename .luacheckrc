std             = "ngx_lua"
unused_args     = false
redefined       = false
max_line_length = 80

-- only lint the library and the tests; build/ and deps/ are vendored/build output
exclude_files = {
  "build/",
  "deps/",
  "t/servroot/",
}
