import ./nimpretty/compiler / [idents,lineinfos, msgs, syntaxes, options, pathutils, layouter]
import   os

type
  PrettyOptions = object
    indWidth: Natural
    maxLineLen: Positive

proc prettyPrint(infile, outfile: string, opt: PrettyOptions){.exportc.} =
  var conf = newConfigRef()
  let fileIdx = fileInfoIdx(conf, AbsoluteFile infile)
  let f = splitFile(outfile)
  conf.outFile = RelativeFile f.name & f.ext
  conf.outDir = toAbsoluteDir f.dir
  var p: TParsers
  p.parser.em.indWidth = opt.indWidth
  if setupParsers(p, fileIdx, newIdentCache(), conf):
    p.parser.em.maxLineLen = opt.maxLineLen
  discard parseAll(p)
  closeParsers(p)