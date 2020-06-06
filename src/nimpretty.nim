import ./nimpretty/compiler / [idents,syntaxes,lineinfos, msgs, parser, options, ./mypathutils, layouter]
# import os

type
  PrettyOptions = object
    indWidth: Natural
    maxLineLen: Positive

# proc prettyPrint(infile, outfile: string, opt: PrettyOptions){.exportc.} =
#   var conf = newConfigRef()
#   let fileIdx = fileInfoIdx(conf, AbsoluteFile infile)
#   let f = splitFile(outfile)
#   conf.outFile = RelativeFile f.name & f.ext
#   conf.outDir = toAbsoluteDir f.dir
#   var p: TParsers
#   p.parser.em.indWidth = opt.indWidth
#   if setupParsers(p, fileIdx, newIdentCache(), conf):
#     p.parser.em.maxLineLen = opt.maxLineLen
#   discard parseAll(p)
#   closeParsers(p)

when isMainModule:
  # var p: TParsers
  var opt = PrettyOptions(maxLineLen:120)
  let f = open "./nimpretty.nim"
  let source = readAll(f)
  f.close
  var cache:IdentCache
  var conf = newConfigRef()
  discard parseString($source,cache,conf)