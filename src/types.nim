type
  GoString* = object
    str*: cstring
    length*: cint

type SignalCallback* = proc(eventMessage: cstring): void {.cdecl.}
