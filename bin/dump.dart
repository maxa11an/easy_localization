import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:merge_map/merge_map.dart';

final _unsuportedCharacters = RegExp(
    r'''^[\n\t ,[\]{}#&*!|<>'"%@']|^[?-]$|^[?-][ \t]|[\n:][ \t]|[ \t]\n|[\n\t ]#|[\n\t :]$''');
const _regexps = [
  r'(?:\(|)(?:"|' +
      r"')(?<SINGLE_1>\w.[^:\r\n]+)(?:" +
      r'"|' +
      r"')(?:\)|)?(?:\n|)\.?(?:\n|)tr\((?<SINGLE_2>.*?)\)",
  r'(?:\(|)(?:"|' +
      r"')(?<PLURAL_1>\w.[^:\r\n]+)(?:" +
      r'"|' +
      r"')(?:\)|)?(?:\n|)\.?(?:\n|)plural\((?<PLURAL_2>.*?)\)",
  r'plural(?:\()(?:"|' +
      r"')(?<PLURAL_1>\w.[^:\r\n]+)(?:" +
      r'"|' +
      r"')(?:\)|)?(?:\s|,+)(?:.*?)(?:\))"
];

void main(List<String> args) {
  if (_isHelpCommand(args)) {
    _printHelperDisplay();
  } else {
    fetchTranslations(_generateOption(args));
  }
}

bool _isHelpCommand(List<String> args) {
  return args.length == 1 && (args[0] == '--help' || args[0] == '-h');
}

void _printHelperDisplay() {
  var parser = _generateArgParser(null);
  print(parser.usage);
}

GenerateOptions _generateOption(List<String> args) {
  var generateOptions = GenerateOptions();
  var parser = _generateArgParser(generateOptions);
  parser.parse(args);
  return generateOptions;
}

ArgParser _generateArgParser(GenerateOptions generateOptions) {
  var parser = ArgParser();

  parser.addOption('output-file',
      abbr: 'o',
      defaultsTo: 'dump',
      callback: (String x) => generateOptions.outputFile = x,
      help: 'Output file name');

  parser.addOption('format',
      abbr: 'f',
      defaultsTo: 'json',
      callback: (String x) => generateOptions.format = x,
      help: 'Support json',
      allowed: ['json', 'yaml']);

  parser.addOption('compare',
      abbr: 'c',
      defaultsTo: 'NOCOMPARE',
      callback: (String x) => generateOptions.compareFile = x,
      help: 'Compare with existing json file'
  );

  return parser;
}

class GenerateOptions {
  String outputFile;
  String format;
  String compareFile;

  @override
  String toString() {
    return 'format: $format outputFile: $outputFile compareFile: $compareFile';
  }
}

Map<String, TranslationKey> _matches = {};

void fetchTranslations(GenerateOptions options) async {
  final outputFile =
      '${Directory.current.path}/${options.outputFile}.${options.format}';
  final source = Directory.fromUri(Uri.parse('./lib'));

  var sourceFiles = await fetchDartFiles(source);

  await readFiles(sourceFiles);

  var _outputMapped = {};

  _matches.forEach((key, value) {
    var list = [];
    list.add(_outputMapped);
    var tmpVal = '#${md5.convert(utf8.encode(key)).toString()}#';
    if (value.isGender) {
      list = addGender(key, tmpVal, list);
    } else if (value.isPlural) {
      list = addPlural(key, tmpVal, list);
    } else {
      list.add(dot2Map(tmpVal, key.split('.').reversed.toList()));
    }
    _outputMapped = mergeMap<dynamic, dynamic>(list.map((e) => e));
  });

  String content;
  switch (options.format) {
    case 'json':
      content = printJSON(_outputMapped);
      break;
    case 'yaml':
      content = printYAML(_outputMapped);
      break;
  }

  if(options.compareFile != '' && options.format == 'json'){
    var compareFile = File(options.compareFile);
    if(compareFile != null){
      var indexedRef = map2Dot(jsonDecode(compareFile.readAsStringSync())).keys;
      var source = map2Dot(jsonDecode(content));
      source.removeWhere((key, value) => indexedRef.contains(key));
      var objects = [];
      source.forEach((key, value) {
        objects.add(dot2Map(value, key.split('.').reversed.toList()));
      });
      content = JsonEncoder.withIndent('  ').convert(mergeMap<dynamic, dynamic>(objects.cast()));
    }
  }



  var f = File(outputFile);
  f.writeAsStringSync(content, flush: true);


}

String printJSON(outputMapped) {
  var encoder = JsonEncoder.withIndent('  ');
  var pretty = encoder.convert(outputMapped);
  _matches.forEach((key, value) {
    pretty = pretty.replaceAll(
        '"#${md5.convert(utf8.encode(key)).toString()}#"',
        '"${value.comment}"');
  });

  return pretty;
}

String printYAML(outputMapped) {
  var pretty = YamlToString().toYamlString(outputMapped);
  _matches.forEach((key, value) {
    pretty = pretty.replaceAll(
        "'#${md5.convert(utf8.encode(key)).toString()}#'",
        "'' #${value.comment}");
  });
  return pretty;
}

/// Adds plural to a dot-notation
List addPlural(String key, String value, List list) {
  list.add(dot2Map(value, '${key}.zero'.split('.').reversed.toList()));
  list.add(dot2Map(value, '${key}.one'.split('.').reversed.toList()));
  list.add(dot2Map(value, '${key}.two'.split('.').reversed.toList()));
  list.add(dot2Map(value, '${key}.few'.split('.').reversed.toList()));
  list.add(dot2Map(value, '${key}.many'.split('.').reversed.toList()));
  list.add(dot2Map(value, '${key}.other'.split('.').reversed.toList()));
  return list;
}

/// Adds genders to dot-notation
List addGender(String key, String value, List list) {
  list.add(dot2Map(value, '${key}.male'.split('.').reversed.toList()));
  list.add(dot2Map(value, '${key}.female'.split('.').reversed.toList()));
  list.add(dot2Map(value, '${key}.other'.split('.').reversed.toList()));

  return list;
}

Future<List<FileSystemEntity>> fetchDartFiles(Directory dir) {
  var files = <FileSystemEntity>[];
  var completer = Completer<List<FileSystemEntity>>();
  var lister = dir.list(recursive: true);
  lister.listen((file) {
    if (file.path.contains('.dart')) {
      files.add(file);
    }
  }, onDone: () => completer.complete(files));
  return completer.future;
}

Future readFiles(List<FileSystemEntity> files) async {
  await files.forEach((fileSystemEntity) async {
    var file = File(fileSystemEntity.path);
    await readFile(file);
  });
  return Future.value();
}

Future readFile(File file) async {
  var filename = file.path.split('/').last;

  var lineNumber = 1;
  file.readAsLinesSync().forEach((line) {
    _regexps.forEach((element) {
      var regexp = RegExp(element, multiLine: true, caseSensitive: false);
      if (regexp.hasMatch(line)) {
        var matches = regexp.allMatches(line);
        matches.forEach((match) {
          var key = match.group(1);
          var args = '';
          var namedArgs = '';

          if (!(_matches[key] is TranslationKey)) {
            _matches[key] = TranslationKey();
          }
          //If it's not a plural
          if (element.contains('<SINGLE')) {
            ///Check if this key is declared as gender before
            if (_matches[key].isGender) {
              if (RegExp(r'gender(?:\s+|):').hasMatch(match.group(2))) {
                printError(
                    'This seemes to be a gender in other places but not here $filename');
              }
            }

            ///Check if this key is gender
            if (match.groupCount >= 2 &&
                RegExp(r'gender(?:\s+|):').hasMatch(match.group(2))) {
              _matches[key].markAsGender();
            }

            var testForArgs =
                RegExp(r'args(?:\s+|):(?:\s+|)\[(.*?)\]', dotAll: true);
            if (testForArgs.hasMatch(match.group(2))) {
              var m = testForArgs.allMatches(match.group(2));
              if (m != null) {
                args = '[${m.elementAt(0).group(1)}]';
              }
            }

            var testForNamedArgs =
                RegExp(r'namedArgs(?:\s+|):(?:\s+|)\{(.*?)\}', dotAll: true);
            if (testForNamedArgs.hasMatch(match.group(2))) {
              var m = testForNamedArgs.allMatches(match.group(2));
              if (m != null) {
                namedArgs = '{${m.elementAt(0).group(1)}}';
              }
            }
            _matches[key].addLocation(filename, lineNumber, args, namedArgs);
          } else {
            _matches[key].markAsPlural();
            _matches[key]
                .addLocation(filename, lineNumber);
          }
        });
      }
    });
    ++lineNumber;
  });
  return Future.value();
}


void printInfo(String info) {
  print('\u001b[32measy localization: $info\u001b[0m');
}

void printError(String error) {
  print('\u001b[31m[ERROR] easy localization: $error\u001b[0m');
}

class TranslationKey {
  Map<String, List<String>> locations = {};
  bool isGender = false;
  bool isPlural = false;

  addLocation(String fileName, dynamic line,
      [String args = '', String namedArgs = '']) {
    if (!(locations[fileName] is List)) {
      locations[fileName] = [];
    }
    locations[fileName].add(
        "$line ${args.isNotEmpty ? "(args: ${args.replaceAll('"', "'")})" : ""} ${namedArgs.isNotEmpty ? "(namedArgs: ${namedArgs.replaceAll('"', "'")})" : ""}"
            .trim());
  }

  void markAsGender() {
    isGender = true;
  }

  void markAsPlural() {
    isPlural = true;
  }

  String get comment {
    var parts = [];
    locations.forEach((key, value) {
      parts.add("$key:${value.join(',')}");
    });
    return parts.join(' | ');
  }
}

Map<dynamic, dynamic> dot2Map(value, List<String> steps) {
  if (steps.length == 1 && value != null) {
    return {steps[0]: value};
  } else {
    return dot2Map({'${steps.removeAt(0)}': value}, steps);
  }
}


Map map2Dot(Map<dynamic, dynamic> obj, [String prepend = '']){
  var resultObj = {};
  obj.forEach((key, value) {
    if(value is Map){
      resultObj = mergeMap([resultObj, map2Dot(value, '$prepend$key.')]);
    }else{
      resultObj['$prepend$key'] = value;
    }
  });

  return resultObj;
}


class YamlToString {
  const YamlToString({
    this.indent = ' ',
    this.quotes = "'",
  });

  final String indent, quotes;
  static final _divider = ': ';

  String toYamlString(node) {
    final stringBuffer = StringBuffer();
    writeYamlString(node, stringBuffer);
    return stringBuffer.toString();
  }

  /// Serializes [node] into a String and writes it to the [sink].
  void writeYamlString(node, StringSink sink) {
    _writeYamlString(node, 0, sink, true);
  }

  void _writeYamlString(
    node,
    int indentCount,
    StringSink stringSink,
    bool isTopLevel,
  ) {
    if (node is Map) {
      _mapToYamlString(node, indentCount, stringSink, isTopLevel);
    } else if (node is Iterable) {
      _listToYamlString(node, indentCount, stringSink, isTopLevel);
    } else if (node is String) {
      stringSink.writeln(_escapeString(node));
    } else if (node is double) {
      stringSink.writeln("!!float $node");
    } else {
      stringSink.writeln(node);
    }
  }

  String _escapeString(String line) {
    line = line.replaceAll('"', r'\"').replaceAll('\n', r'\n');

    if (line.contains(_unsuportedCharacters)) {
      line = quotes + line + quotes;
    }

    return line;
  }

  void _mapToYamlString(
    node,
    int indentCount,
    StringSink stringSink,
    bool isTopLevel,
  ) {
    if (!isTopLevel) {
      stringSink.writeln();
      indentCount += 2;
    }

    final keys = _sortKeys(node);

    keys.forEach((key) {
      final value = node[key];
      _writeIndent(indentCount, stringSink);
      stringSink..write(key)..write(_divider);
      _writeYamlString(value, indentCount, stringSink, false);
    });
  }

  Iterable<String> _sortKeys(Map map) {
    final simple = <String>[],
        maps = <String>[],
        lists = <String>[],
        other = <String>[];

    map.forEach((key, value) {
      if (value is String) {
        simple.add(key);
      } else if (value is Map) {
        maps.add(key);
      } else if (value is Iterable) {
        lists.add(key);
      } else {
        other.add(key);
      }
    });

    return [...simple, ...maps, ...lists, ...other];
  }

  void _listToYamlString(
    Iterable node,
    int indentCount,
    StringSink stringSink,
    bool isTopLevel,
  ) {
    if (!isTopLevel) {
      stringSink.writeln();
      indentCount += 2;
    }

    node.forEach((value) {
      _writeIndent(indentCount, stringSink);
      stringSink.write('- ');
      _writeYamlString(value, indentCount, stringSink, false);
    });
  }

  void _writeIndent(int indentCount, StringSink stringSink) =>
      stringSink.write(indent * indentCount);
}

// Compare functions to use when using a reference to find new keys
get(obj, path) {
  return path.split('.').reduce((r, e) {
    if (!r) return r;
    else return r[e] ?? null;
  }, obj);
}

bool isEmpty(Map o) {
  if (o is Map) {
    return true;
  }
  return o.keys.toList().isNotEmpty;
}

build(a, b, [o, prev = '']){
  return a.keys.reduce((r, e) {
    var path = prev + (prev ? '.' + e : e);
    var bObj = get(b, path);
    var value = a[e] == bObj;

    if(a[e] is Map){
      if(isEmpty(a[e]) && isEmpty(bObj)){
        if(r.contains(e)){
          r[e] = r[e];
        }else{
          r[e] = true;
        }
      }else if(bObj != null && isEmpty(a[e])){
        r[e] = value;
      } else{
        r[e] = build(a[e], b, r[e], path);
      }
    }else{
      r[e] = value;
    }
    return r;
  }, o ? o : {});
}

compare(a, b){
  var o = build(a,b);
  return build(b, a, o);
}