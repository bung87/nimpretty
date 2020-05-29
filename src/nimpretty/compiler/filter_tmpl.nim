#
#
#           The Nim Compiler
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# This module implements Nim's standard template filter.

import
  streams, strutils, ast, msgs, options,
  filters, lineinfos, pathutils

type
  TParseState = enum
    psDirective, psTempl
  TTmplParser = object
    inp: Stream
    state: TParseState
    info: TLineInfo
    indent, emitPar: int
    x: string                # the current input line
    outp: Stream          # the output will be parsed by pnimsyn
    subsChar, nimDirective: char
    emit, conc, toStr: string
    curly, bracket, par: int
    pendingExprLine: bool
    config: ConfigRef

const
  PatternChars = {'a'..'z', 'A'..'Z', '0'..'9', '\x80'..'\xFF', '.', '_'}

proc newLine(p: var TTmplParser) =
  write(p.outp, repeat(')', p.emitPar))
  p.emitPar = 0
  if p.info.line > uint16(1): write(p.outp, "\n")
  if p.pendingExprLine:
    write(p.outp, spaces(2))
    p.pendingExprLine = false

proc scanPar(p: var TTmplParser, d: int) =
  var i = d
  while i < p.x.len:
    case p.x[i]
    of '(': inc(p.par)
    of ')': dec(p.par)
    of '[': inc(p.bracket)
    of ']': dec(p.bracket)
    of '{': inc(p.curly)
    of '}': dec(p.curly)
    else: discard
    inc(i)

proc withInExpr(p: TTmplParser): bool {.inline.} =
  result = p.par > 0 or p.bracket > 0 or p.curly > 0

const
  LineContinuationOprs = {'+', '-', '*', '/', '\\', '<', '>', '^',
                          '|', '%', '&', '$', '@', '~', ','}

proc parseLine(p: var TTmplParser) =
  var j = 0
  let len = p.x.len

  while j < len and p.x[j] == ' ': inc(j)

  if len >= 2 and p.x[0] == p.nimDirective and p.x[1] == '?':
    newLine(p)
  elif j < len and p.x[j] == p.nimDirective:
    newLine(p)
    inc(j)
    while j < len and p.x[j] == ' ': inc(j)
    let d = j
    var keyw = ""
    while j < len and p.x[j] in PatternChars:
      keyw.add(p.x[j])
      inc(j)

    scanPar(p, j)
    p.pendingExprLine = withInExpr(p) or p.x[p.x.len - 1] in (LineContinuationOprs)
    case keyw
    of "end":
      if p.indent >= 2:
        dec(p.indent, 2)
      else:
        p.info.col = int16(j)
        discard
        # localError(p.config, p.info, "'end' does not close a control flow construct")
      write(p.outp, spaces(p.indent))
      write(p.outp, "#end")
    of "if", "when", "try", "while", "for", "block", "case", "proc", "iterator",
       "converter", "macro", "template", "method", "func":
      write(p.outp, spaces(p.indent))
      write(p.outp, substr(p.x, d))
      inc(p.indent, 2)
    of "elif", "of", "else", "except", "finally":
      write(p.outp, spaces(p.indent - 2))
      write(p.outp, substr(p.x, d))
    of "let", "var", "const", "type":
      write(p.outp, spaces(p.indent))
      write(p.outp, substr(p.x, d))
      if not p.x.contains({':', '='}):
        # no inline element --> treat as block:
        inc(p.indent, 2)
    else:
      write(p.outp, spaces(p.indent))
      write(p.outp, substr(p.x, d))
    p.state = psDirective
  else:
    # data line
    # reset counters
    p.par = 0
    p.curly = 0
    p.bracket = 0
    j = 0
    case p.state
    of psTempl:
      # next line of string literal:
      write(p.outp, p.conc)
      write(p.outp, "\n")
      write(p.outp, spaces(p.indent + 2))
      write(p.outp, "\"")
    of psDirective:
      newLine(p)
      write(p.outp, spaces(p.indent))
      write(p.outp, p.emit)
      write(p.outp, "(\"")
      inc(p.emitPar)
    p.state = psTempl
    while j < len:
      case p.x[j]
      of '\x01'..'\x1F', '\x80'..'\xFF':
        write(p.outp, "\\x")
        write(p.outp, toHex(ord(p.x[j]), 2))
        inc(j)
      of '\\':
        write(p.outp, "\\\\")
        inc(j)
      of '\'':
        write(p.outp, "\\\'")
        inc(j)
      of '\"':
        write(p.outp, "\\\"")
        inc(j)
      else:
        if p.x[j] == p.subsChar:
          # parse Nim expression:
          inc(j)
          case p.x[j]
          of '{':
            p.info.col = int16(j)
            write(p.outp, '\"')
            write(p.outp, p.conc)
            write(p.outp, p.toStr)
            write(p.outp, '(')
            inc(j)
            var curly = 0
            while j < len:
              case p.x[j]
              of '{':
                inc(j)
                inc(curly)
                write(p.outp, '{')
              of '}':
                inc(j)
                if curly == 0: break
                if curly > 0: dec(curly)
                write(p.outp, '}')
              else:
                write(p.outp, p.x[j])
                inc(j)
            if curly > 0:
              discard
              # localError(p.config, p.info, "expected closing '}'")
              break
            write(p.outp, ')')
            write(p.outp, p.conc)
            write(p.outp, '\"')
          of 'a'..'z', 'A'..'Z', '\x80'..'\xFF':
            write(p.outp, '\"')
            write(p.outp, p.conc)
            write(p.outp, p.toStr)
            write(p.outp, '(')
            while j < len and p.x[j] in PatternChars:
              write(p.outp, p.x[j])
              inc(j)
            write(p.outp, ')')
            write(p.outp, p.conc)
            write(p.outp, '\"')
          else:
            if p.x[j] == p.subsChar:
              write(p.outp, p.subsChar)
              inc(j)
            else:
              p.info.col = int16(j)
              discard
              # localError(p.config, p.info, "invalid expression")
        else:
          write(p.outp, p.x[j])
          inc(j)
    write(p.outp, "\\n\"")

proc filterTmpl*(stdin: Stream, filename: AbsoluteFile,
                 call: PNode; conf: ConfigRef): Stream =
  var p: TTmplParser
  p.config = conf
  p.info = newLineInfo( filename.FileIndex, 0, 0)
  p.outp = newStringStream("")
  p.inp = stdin
  p.subsChar = charArg(conf, call, "subschar", 1, '$')
  p.nimDirective = charArg(conf, call, "metachar", 2, '#')
  p.emit = strArg(conf, call, "emit", 3, "result.add")
  p.conc = strArg(conf, call, "conc", 4, " & ")
  p.toStr = strArg(conf, call, "tostring", 5, "$")
  p.x = newStringOfCap(120)
  # do not process the first line which contains the directive:
  if readLine(p.inp, p.x):
    p.info.line = p.info.line + 1'u16
  while readLine(p.inp, p.x):
    p.info.line = p.info.line + 1'u16
    parseLine(p)
  newLine(p)
  result = p.outp
  close(p.inp)
