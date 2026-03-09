# Unsupported jq Test Cases

| Line | Filter | Reason |
|------|--------|--------|
| 39 | `{x:-1},{x:-.},{x:-.\|abs}` | Arithmetic |
| 68 | `"inter\("pol" + "ation")"` | Arithmetic |
| 72 | `@text,@json,([1,.]\|@csv,@tsv),@html,(...` | Complex expressions |
| 102 | `@html "<b>\(.)</b>"` | Arithmetic |
| 114 | `{a: 1}` | Object/array construction |
| 118 | `{a,b,(.d):.a,e:.b}` | Complex expressions |
| 122 | `{"a",b,"a$\(1+1)"}` | Arithmetic |
| 200 | `map(try .a[] catch ., try .a.[] catch...` | Error handling |
| 205 | `try ["OK", (.[] \| error)] catch ["KO"...` | Error handling |
| 213 | `try (.foo[-1] = 0) catch .` | Arithmetic |
| 217 | `try (.foo[-2] = 0) catch .` | Arithmetic |
| 229 | `try (.[999999999] = 0) catch .` | Error handling |
| 261 | `[{}]` | Unsupported syntax |
| 269 | `[(.,1),((.,.[]),(2,3))]` | Complex expressions |
| 273 | `[([5,5][]),.,.[]]` | Complex expressions |
| 277 | `{x: (1,2)},{x:3} \| .x` | Complex expressions |
| 287 | `[range(0;10)]` | Complex expressions |
| 291 | `[range(0,1;3,4)]` | Complex expressions |
| 295 | `[range(0;10;3)]` | Complex expressions |
| 299 | `[range(0;10;-1)]` | Arithmetic |
| 303 | `[range(0;-5;-1)]` | Arithmetic |
| 307 | `[range(0,1;4,5;1,2)]` | Complex expressions |
| 311 | `[while(.<100; .*2)]` | Arithmetic |
| 315 | `[(label $here \| .[] \| if .>1 then bre...` | Comparison |
| 319 | `[(label $here \| .[] \| if .>1 then bre...` | Comparison |
| 329 | `[.[]\|[.,1]\|until(.[0] < 1; [.[0] - 1,...` | Arithmetic |
| 333 | `[label $out \| foreach .[] as $item ([...` | Arithmetic |
| 337 | `[foreach range(5) as $item (0; $item)]` | Iteration |
| 341 | `[foreach .[] as [$i, $j] (0; . + $i -...` | Arithmetic |
| 345 | `[foreach .[] as {a:$a} (0; . + $a; -.)]` | Arithmetic |
| 349 | `[-foreach -.[] as $x (0; . + $x)]` | Arithmetic |
| 353 | `[foreach .[] / .[] as $i (0; . + $i)]` | Arithmetic |
| 357 | `[foreach .[] as $x (0; . + $x) as $x ...` | Arithmetic |
| 361 | `[limit(3; .[])]` | Complex expressions |
| 365 | `[limit(0; error)]` | Complex expressions |
| 369 | `[limit(1; 1, error)]` | Complex expressions |
| 373 | `try limit(-1; error) catch .` | Arithmetic |
| 377 | `[skip(3; .[])]` | Complex expressions |
| 381 | `[skip(0,2,3,4; .[])]` | Complex expressions |
| 385 | `[skip(3; .[])]` | Complex expressions |
| 389 | `try skip(-1; error) catch .` | Arithmetic |
| 393 | `nth(1; 0,1,error("foo"))` | Complex expressions |
| 397 | `[first(range(.)), last(range(.))]` | Complex expressions |
| 401 | `[first(range(.)), last(range(.))]` | Complex expressions |
| 405 | `[nth(0,5,9,10,15; range(.)), try nth(...` | Arithmetic |
| 410 | `first(1,error("foo"))` | Complex expressions |
| 420 | `[limit(5,7; range(9))]` | Complex expressions |
| 425 | `[nth(5,7; range(9;0;-1))]` | Arithmetic |
| 430 | `[range(0,1,2;4,3,2;2,3)]` | Complex expressions |
| 435 | `[range(3,5)]` | Complex expressions |
| 440 | `[(index(",","\|"), rindex(",","\|")), i...` | Complex expressions |
| 445 | `join(",","/")` | Arithmetic |
| 450 | `[.[]\|join("a")]` | Complex expressions |
| 455 | `flatten(3,2,1)` | Complex expressions |
| 474 | `del(.[2:4],.[0],.[-2:])` | Arithmetic |
| 478 | `.[2:4] = ([], ["a","b"], ["a","b","c"])` | Complex expressions |
| 490 | `reduce range(65540;65536;-1) as $i ([...` | Arithmetic |
| 498 | `1 as $x \| 2 as $y \| [$x,$y,$x]` | Variables |
| 502 | `[1,2,3][] as $x \| [[4,5,6,7][$x]]` | Variables |
| 508 | `42 as $x \| . \| . \| . + 432 \| $x + 1` | Arithmetic |
| 512 | `1 + 2 as $x \| -$x` | Arithmetic |
| 516 | `"x" as $x \| "a"+"y" as $y \| $x+","+$y` | Arithmetic |
| 520 | `1 as $x \| [$x,$x,$x as $x \| $x]` | Variables |
| 524 | `[1, {c:3, d:4}] as [$a, {c:$b, b:$c}]...` | Variables |
| 530 | `. as {as: $kw, "str": $str, ("e"+"x"+...` | Arithmetic |
| 534 | `.[] as [$a, $b] \| [$b, $a]` | Variables |
| 539 | `. as $i \| . as [$i] \| $i` | Variables |
| 543 | `. as [$i] \| . as $i \| $i` | Variables |
| 589 | `2-(-1)` | Arithmetic |
| 617 | `{"a":1} + {"b":2} + {"c":3}` | Arithmetic |
| 637 | `[-1 as $x \| 1,$x]` | Arithmetic |
| 674 | `(1e999999999, 10e999999999) > (1e-114...` | Arithmetic |
| 689 | `[(infinite, -infinite) % (1, -1, infi...` | Arithmetic |
| 697 | `1 + tonumber + ("10" \| tonumber)` | Arithmetic |
| 701 | `"123\u0000456" \| try tonumber catch .` | Error handling |
| 705 | `map(toboolean)` | Complex expressions |
| 709 | `.[] \| try toboolean catch .` | Error handling |
| 720 | `"true\u0000x", "false\u0000" \| try to...` | Error handling |
| 725 | `[{"a":42},.object,10,.num,false,true,...` | Comparison |
| 737 | `[.[] \| length]` | Builtins |
| 745 | `[.[] \| try utf8bytelength catch .]` | Error handling |
| 750 | `map(keys)` | Complex expressions |
| 758 | `map(add)` | Complex expressions |
| 762 | `map_values(.+1)` | Arithmetic |
| 766 | `[add(null), add(range(range(10))), ad...` | Complex expressions |
| 771 | `.sum = add(.arr[])` | Complex expressions |
| 775 | `add({(.[]):1}) \| keys` | Complex expressions |
| 784 | `def f: . + 1; def g: def g: . + 100; ...` | Arithmetic |
| 789 | `def f: (1000,2000); f` | Complex expressions |
| 794 | `def f(a;b;c;d;e;f): [a+1,b,c,d,e,f]; ...` | Arithmetic |
| 808 | `def f(a;b;c;d;e;f;g;h;i;j): [j,i,h,g,...` | Complex expressions |
| 812 | `([1,2] + [4,5])` | Arithmetic |
| 838 | `(add / length) as $m \| map((. - $m) a...` | Arithmetic |
| 851 | `[(3.141592 / 2) * (range(0;20) / 20)\|...` | Arithmetic |
| 855 | `[(3.141592 / 2) * (range(0;20) / 20)\|...` | Arithmetic |
| 860 | `def f(x): x \| x; f([.], . + [42])` | Arithmetic |
| 868 | `def f: .+1; def g: f; def f: .+100; d...` | Arithmetic |
| 873 | `def id(x):x; 2000 as $x \| def f(x):1 ...` | Arithmetic |
| 878 | `def x(a;b): a as $a \| b as $b \| $a + ...` | Arithmetic |
| 884 | `[[20,10][1,0] as $x \| def f: (100,200...` | Arithmetic |
| 889 | `def fac: if . == 1 then 1 else . * (....` | Arithmetic |
| 899 | `reduce .[] as $x (0; . + $x)` | Arithmetic |
| 903 | `reduce .[] as [$i, {j:$j}] (0; . + $i...` | Arithmetic |
| 907 | `reduce [[1,2,10], [3,4,10]][] as [$i,...` | Arithmetic |
| 911 | `[-reduce -.[] as $x (0; . + $x)]` | Arithmetic |
| 915 | `[reduce .[] / .[] as $i (0; . + $i)]` | Arithmetic |
| 919 | `reduce .[] as $x (0; . + $x) as $x \| $x` | Arithmetic |
| 924 | `reduce . as $n (.; .)` | Iteration |
| 929 | `. as {$a, b: [$c, {$d}]} \| [$a, $c, $d]` | Variables |
| 933 | `. as {$a, $b:[$c, $d]}\| [$a, $b, $c, $d]` | Variables |
| 938 | `.[] \| . as {$a, b: [$c, {$d}]} ?// [$...` | Arithmetic |
| 945 | `.[] \| . as {a:$a} ?// {a:$a} ?// {a:$...` | Arithmetic |
| 949 | `.[] as {a:$a} ?// {a:$a} ?// {a:$a} \| $a` | Arithmetic |
| 953 | `[[3],[4],[5],6][] \| . as {a:$a} ?// {...` | Arithmetic |
| 957 | `[[3],[4],[5],6] \| .[] as {a:$a} ?// {...` | Arithmetic |
| 961 | `.[] \| . as {a:$a} ?// {a:$a} ?// $a \| $a` | Arithmetic |
| 968 | `.[] as {a:$a} ?// {a:$a} ?// $a \| $a` | Arithmetic |
| 975 | `[[3],[4],[5],6][] \| . as {a:$a} ?// {...` | Arithmetic |
| 982 | `[[3],[4],[5],6] \| .[] as {a:$a} ?// {...` | Arithmetic |
| 989 | `.[] \| . as {a:$a} ?// $a ?// {a:$a} \| $a` | Arithmetic |
| 996 | `.[] as {a:$a} ?// $a ?// {a:$a} \| $a` | Arithmetic |
| 1003 | `[[3],[4],[5],6][] \| . as {a:$a} ?// $...` | Arithmetic |
| 1010 | `[[3],[4],[5],6] \| .[] as {a:$a} ?// $...` | Arithmetic |
| 1017 | `.[] \| . as $a ?// {a:$a} ?// {a:$a} \| $a` | Arithmetic |
| 1024 | `.[] as $a ?// {a:$a} ?// {a:$a} \| $a` | Arithmetic |
| 1031 | `[[3],[4],[5],6][] \| . as $a ?// {a:$a...` | Arithmetic |
| 1038 | `[[3],[4],[5],6] \| .[] as $a ?// {a:$a...` | Arithmetic |
| 1045 | `. as $dot\|any($dot[];not)` | Variables |
| 1049 | `. as $dot\|any($dot[];not)` | Variables |
| 1053 | `. as $dot\|all($dot[];.)` | Variables |
| 1057 | `. as $dot\|all($dot[];.)` | Variables |
| 1062 | `any(true, error; .)` | Complex expressions |
| 1066 | `all(false, error; .)` | Complex expressions |
| 1070 | `any(not)` | Complex expressions |
| 1074 | `all(not)` | Complex expressions |
| 1078 | `any(not)` | Complex expressions |
| 1082 | `all(not)` | Complex expressions |
| 1110 | `path(.foo[0,1])` | Complex expressions |
| 1115 | `path(.[] \| select(.>3))` | Comparison |
| 1119 | `path(.)` | Complex expressions |
| 1123 | `try path(.a \| map(select(.b == 0))) c...` | Comparison |
| 1127 | `try path(.a \| map(select(.b == 0)) \| ...` | Comparison |
| 1131 | `try path(.a \| map(select(.b == 0)) \| ...` | Comparison |
| 1135 | `try path(.a \| map(select(.b == 0)) \| ...` | Comparison |
| 1139 | `path(.a[path(.b)[0]])` | Complex expressions |
| 1147 | `["foo",1] as $p \| getpath($p), setpat...` | Variables |
| 1153 | `map(getpath([2])), map(setpath([2]; 4...` | Complex expressions |
| 1159 | `map(delpaths([[0,"foo"]]))` | Complex expressions |
| 1163 | `["foo",1] as $p \| getpath($p), setpat...` | Variables |
| 1169 | `delpaths([[-200]])` | Arithmetic |
| 1173 | `try delpaths(0) catch .` | Error handling |
| 1177 | `del(.), del(empty), del((.foo,.bar,.b...` | Complex expressions |
| 1184 | `del(.[1], .[-6], .[2], .[-3:9])` | Arithmetic |
| 1188 | `del(.[nan])` | Complex expressions |
| 1192 | `del(.[nan,nan])` | Complex expressions |
| 1197 | `setpath([-1]; 1)` | Arithmetic |
| 1201 | `pick(.a.b.c)` | Complex expressions |
| 1205 | `pick(first)` | Complex expressions |
| 1209 | `pick(first\|first)` | Complex expressions |
| 1214 | `try pick(last) catch .` | Error handling |
| 1233 | `.[] += 2, .[] *= 2, .[] -= 2, .[] /= ...` | Arithmetic |
| 1245 | `.foo += .foo` | Arithmetic |
| 1249 | `.[0].a \|= {"old":., "new":(.+1)}` | Arithmetic |
| 1253 | `def inc(x): x \|= .+1; inc(.[].a)` | Arithmetic |
| 1258 | `.[] \| try (getpath(["a",0,"b"]) \|= 5)...` | Error handling |
| 1270 | `(.[] \| select(. >= 2)) \|= empty` | Comparison |
| 1274 | `.[] \|= select(. % 2 == 0)` | Arithmetic |
| 1290 | `try ((map(select(.a == 1))[].b) = 10)...` | Comparison |
| 1294 | `try ((map(select(.a == 1))[].a) \|= .+...` | Arithmetic |
| 1302 | `try (def x: reverse; x=10) catch .` | Error handling |
| 1314 | `[.[] \| if .foo then "yep" else "nope"...` | Conditional |
| 1318 | `[.[] \| if .baz then "strange" elif .f...` | Conditional |
| 1322 | `[if 1,null,2 then 3 else 4 end]` | Conditional |
| 1326 | `[if empty then 3 else 4 end]` | Conditional |
| 1330 | `[if 1 then 3,4 else 5 end]` | Conditional |
| 1334 | `[if null then 3 else 5,6 end]` | Conditional |
| 1338 | `[if true then 3 end]` | Conditional |
| 1342 | `[if false then 3 end]` | Conditional |
| 1346 | `[if false then 3 else . end]` | Conditional |
| 1350 | `[if false then 3 elif false then 4 end]` | Conditional |
| 1354 | `[if false then 3 elif false then 4 el...` | Conditional |
| 1358 | `[-if true then 1 else 2 end]` | Arithmetic |
| 1362 | `{x: if true then 1 else 2 end}` | Conditional |
| 1366 | `if true then [.] else . end []` | Conditional |
| 1374 | `.[] //= .[0]` | Arithmetic |
| 1411 | `[{"foo":42} == {"foo":42},{"foo":42} ...` | Comparison |
| 1416 | `[{"foo":[1,2,{"bar":18},"world"]} == ...` | Comparison |
| 1421 | `[("foo" \| contains("foo")), ("foobar"...` | Complex expressions |
| 1426 | `[contains(""), contains("\u0000")]` | Complex expressions |
| 1430 | `[contains(""), contains("a"), contain...` | Complex expressions |
| 1434 | `[contains("cd"), contains("b\u0000"),...` | Complex expressions |
| 1438 | `[contains("b\u0000c"), contains("b\u0...` | Complex expressions |
| 1442 | `[contains("@"), contains("\u0000@"), ...` | Complex expressions |
| 1448 | `[.[]\|try if . == 0 then error("foo") ...` | Comparison |
| 1452 | `[.[]\|(.a, .a)?]` | Complex expressions |
| 1460 | `[if error then 1 else 2 end?]` | Conditional |
| 1464 | `try error(0) // 1` | Arithmetic |
| 1468 | `1, try error(2), 3` | Error handling |
| 1473 | `1 + try 2 catch 3 + 4` | Arithmetic |
| 1477 | `[-try .]` | Arithmetic |
| 1481 | `try -.? catch .` | Arithmetic |
| 1485 | `{x: try 1, y: try error catch 2, z: i...` | Conditional |
| 1489 | `{x: 1 + 2, y: false or true, z: null ...` | Arithmetic |
| 1493 | `.[] \| try error catch .` | Error handling |
| 1499 | `try error("\($__loc__)") catch .` | Error handling |
| 1504 | `[.[]\|startswith("foo")]` | Complex expressions |
| 1508 | `[.[]\|endswith("foo")]` | Conditional |
| 1512 | `[.[] \| split(", ")]` | Complex expressions |
| 1516 | `split("")` | Complex expressions |
| 1520 | `[.[]\|ltrimstr("foo")]` | Complex expressions |
| 1524 | `[.[]\|rtrimstr("foo")]` | Complex expressions |
| 1528 | `[.[]\|trimstr("foo")]` | Complex expressions |
| 1532 | `[.[]\|ltrimstr("")]` | Complex expressions |
| 1536 | `[.[]\|rtrimstr("")]` | Complex expressions |
| 1540 | `[.[]\|trimstr("")]` | Complex expressions |
| 1544 | `[(index(","), rindex(",")), indices("...` | Complex expressions |
| 1548 | `[ index("aba"), rindex("aba"), indice...` | Complex expressions |
| 1554 | `map(trim), map(ltrim), map(rtrim)` | Complex expressions |
| 1566 | `try trim catch ., try ltrim catch ., ...` | Error handling |
| 1572 | `indices(1)` | Complex expressions |
| 1576 | `indices([1,2])` | Complex expressions |
| 1580 | `indices([1,2])` | Complex expressions |
| 1584 | `indices(", ")` | Complex expressions |
| 1588 | `index("!")` | Complex expressions |
| 1592 | `.[:rindex("x")]` | Complex expressions |
| 1596 | `indices("o")` | Complex expressions |
| 1600 | `indices("o")` | Complex expressions |
| 1604 | `[.[]\|split(",")]` | Complex expressions |
| 1608 | `[.[]\|split(", ")]` | Complex expressions |
| 1620 | `[. * (nan,-nan)]` | Arithmetic |
| 1632 | `try (. * 1000000000) catch .` | Arithmetic |
| 1644 | `map(.[1] as $needle \| .[0] \| contains...` | Variables |
| 1648 | `map(.[1] as $needle \| .[0] \| contains...` | Variables |
| 1652 | `[({foo: 12, bar:13} \| contains({foo: ...` | Complex expressions |
| 1656 | `{foo: {baz: 12, blap: {bar: 13}}, bar...` | Complex expressions |
| 1660 | `{foo: {baz: 12, blap: {bar: 13}}, bar...` | Complex expressions |
| 1668 | `(sort_by(.b) \| sort_by(.a)), sort_by(...` | Arithmetic |
| 1684 | `[min, max, min_by(.[1]), max_by(.[1])...` | Complex expressions |
| 1688 | `[min,max,min_by(.),max_by(.)]` | Complex expressions |
| 1700 | `[{a:1}] \| .[] \| .a=999` | Object/array construction |
| 1712 | `with_entries(.key \|= "KEY_" + .)` | Arithmetic |
| 1716 | `map(has("foo"))` | Complex expressions |
| 1720 | `map(has(2))` | Complex expressions |
| 1724 | `has(nan)` | Complex expressions |
| 1728 | `keys` | Builtins |
| 1736 | `map([1,2][0:.])` | Complex expressions |
| 1742 | `{"k": {"a": 1, "b": 2}} * .` | Arithmetic |
| 1746 | `{"k": {"a": 1, "b": 2}, "hello": {"x"...` | Arithmetic |
| 1750 | `{"k": {"a": 1, "b": 2}, "hello": 1} * .` | Arithmetic |
| 1754 | `{"a": {"b": 1}, "c": {"d": 2}, "e": 5...` | Arithmetic |
| 1774 | `[.[]\|values]` | Builtins |
| 1790 | `flatten(0)` | Complex expressions |
| 1794 | `flatten(2)` | Complex expressions |
| 1798 | `flatten(2)` | Complex expressions |
| 1802 | `try flatten(-1) catch .` | Arithmetic |
| 1818 | `bsearch(0,1,2,3,4)` | Complex expressions |
| 1826 | `bsearch({x:1})` | Complex expressions |
| 1830 | `try ["OK", bsearch(0)] catch ["KO",.]` | Error handling |
| 1834 | `strftime("%Y-%m-%dT%H:%M:%SZ")` | Arithmetic |
| 1838 | `strftime("%A, %B %d, %Y")` | Arithmetic |
| 1842 | `strftime("%Y-%m-%dT%H:%M:%SZ")` | Arithmetic |
| 1859 | `try strftime("%Y-%m-%dT%H:%M:%SZ") ca...` | Arithmetic |
| 1863 | `try strflocaltime("%Y-%m-%dT%H:%M:%SZ...` | Arithmetic |
| 1867 | `try mktime catch .` | Error handling |
| 1872 | `try ["OK", strftime([])] catch ["KO", .]` | Error handling |
| 1876 | `try ["OK", strflocaltime({})] catch [...` | Error handling |
| 1880 | `[strptime("%Y-%m-%dT%H:%M:%SZ")\|(.,mk...` | Arithmetic |
| 1886 | `last(range(365 * 67)\|("1970-03-01T01:...` | Arithmetic |
| 1891 | `import "a" as foo; import "b" as bar;...` | Variables |
| 1895 | `import "c" as foo; [foo::a, foo::c]` | Variables |
| 1903 | `import "data" as $e; import "data" as...` | Variables |
| 1908 | `import "data" as $a; import "data" as...` | Variables |
| 1920 | `import "shadow1" as f; import "shadow...` | Variables |
| 1964 | `modulemeta \| .deps \| length` | Builtins |
| 1968 | `modulemeta \| .defs \| length` | Builtins |
| 1984 | `import "test_bind_order" as check; ch...` | Variables |
| 1988 | `try -. catch .` | Arithmetic |
| 1992 | `try (.-.) catch .` | Arithmetic |
| 1996 | `"x" * range(0; 12; 2) + "☆" * 8 \| try...` | Arithmetic |
| 2005 | `try (. + "x") catch . == if have_decn...` | Arithmetic |
| 2009 | `join(",")` | Complex expressions |
| 2013 | `.[] \| join(",")` | Complex expressions |
| 2020 | `.[] \| join(",")` | Complex expressions |
| 2025 | `try join(",") catch .` | Error handling |
| 2029 | `try join(",") catch .` | Error handling |
| 2033 | `{if:0,and:1,or:2,then:3,else:4,elif:5...` | Conditional |
| 2037 | `try (1/.) catch .` | Arithmetic |
| 2041 | `try (1/0) catch .` | Arithmetic |
| 2045 | `try (0/0) catch .` | Arithmetic |
| 2049 | `try (1%.) catch .` | Arithmetic |
| 2053 | `try (1%0) catch .` | Arithmetic |
| 2058 | `[range(-52;52;1)] as $powers \| [$powe...` | Arithmetic |
| 2062 | `[range(-99/2;99/2;1)] as $orig \| [$or...` | Arithmetic |
| 2077 | `(.[{}] = 0)?` | Complex expressions |
| 2080 | `INDEX(range(5)\|[., "foo\(.)"]; .[0])` | Complex expressions |
| 2084 | `JOIN({"0":[0,"abc"],"1":[1,"bcd"],"2"...` | Complex expressions |
| 2088 | `range(5;10)\|IN(range(10))` | Complex expressions |
| 2096 | `range(5;13)\|IN(range(0;10;3))` | Complex expressions |
| 2107 | `range(10;12)\|IN(range(10))` | Complex expressions |
| 2112 | `IN(range(10;20); range(10))` | Complex expressions |
| 2116 | `IN(range(5;20); range(10))` | Complex expressions |
| 2121 | `(.a as $x \| .b) = "b"` | Variables |
| 2126 | `(.. \| select(type == "object" and has...` | Comparison |
| 2130 | `isempty(empty)` | Complex expressions |
| 2134 | `isempty(range(3))` | Complex expressions |
| 2138 | `isempty(1,error("foo"))` | Complex expressions |
| 2143 | `index("")` | Complex expressions |
| 2148 | `builtins\|length > 10` | Comparison |
| 2152 | `"-1"\|IN(builtins[] / "/"\|.[1])` | Arithmetic |
| 2156 | `all(builtins[] / "/"; .[1]\|tonumber >...` | Arithmetic |
| 2160 | `builtins\|any(.[:1] == "_")` | Comparison |
| 2181 | `map(. == 1)` | Comparison |
| 2187 | `.[0] \| tostring \| . == if have_decnum...` | Comparison |
| 2191 | `.x \| tojson \| . == if have_decnum the...` | Comparison |
| 2195 | `(13911860366432393 == 139118603664323...` | Comparison |
| 2215 | `-. \| tojson == if have_decnum then "-...` | Arithmetic |
| 2219 | `-. \| tojson == if have_decnum then "0...` | Arithmetic |
| 2223 | `[1E+1000,-1E+1000 \| tojson] == if hav...` | Arithmetic |
| 2227 | `. \|= try . catch .` | Error handling |
| 2232 | `.[] as $n \| $n+0 \| [., tostring, . ==...` | Arithmetic |
| 2245 | `map(abs)` | Complex expressions |
| 2249 | `map(fabs)` | Complex expressions |
| 2253 | `map(abs == length) \| unique` | Comparison |
| 2258 | `map(abs)` | Complex expressions |
| 2262 | `[1E+1000,-1E+1000 \| abs \| tojson] \| u...` | Arithmetic |
| 2266 | `[1E+1000,-1E+1000 \| length \| tojson] ...` | Arithmetic |
| 2272 | `123 as $label \| $label` | Variables |
| 2276 | `[ label $if \| range(10) \| ., (select(...` | Comparison |
| 2280 | `reduce .[] as $then (4 as $else \| $el...` | Arithmetic |
| 2284 | `1 as $foreach \| 2 as $and \| 3 as $or ...` | Iteration |
| 2288 | `[ foreach .[] as $try (1 as $catch \| ...` | Arithmetic |
| 2295 | `{ a, $__loc__, c }` | Variables |
| 2299 | `1 as $x \| "2" as $y \| "3" as $z \| { $...` | Conditional |
| 2315 | `.[] \| try (fromjson \| isnan) catch .` | Error handling |
| 2328 | `try input catch .` | Error handling |
| 2337 | `"foo" \| try ((try . catch "caught too...` | Error handling |
| 2341 | `.[]\|(try (if .=="hi" then . else erro...` | Comparison |
| 2345 | `try (["hi","ho"]\|.[]\|(try . catch (if...` | Comparison |
| 2350 | `.[]\|(try . catch (if .=="ho" then "BR...` | Comparison |
| 2354 | `try (try error catch "inner catch \(....` | Error handling |
| 2358 | `try ((try error catch "inner catch \(...` | Error handling |
| 2363 | `first(.?,.?)` | Complex expressions |
| 2368 | `{foo: "bar"} \| .foo \|= .?` | Object/array construction |
| 2373 | `. \|= try 2` | Error handling |
| 2377 | `. \|= try 2 catch 3` | Error handling |
| 2381 | `.[] \|= try tonumber` | Error handling |
| 2386 | `any(keys[]\|tostring?;true)` | Complex expressions |
| 2398 | `map(try implode catch .)` | Error handling |
| 2402 | `try 0[implode] catch .` | Error handling |
| 2407 | `walk(.)` | Complex expressions |
| 2411 | `walk(1)` | Complex expressions |
| 2416 | `[walk(.,1)]` | Complex expressions |
| 2421 | `walk(select(IN({}, []) \| not))` | Complex expressions |
| 2426 | `[range(10)] \| .[1.2:3.5]` | Complex expressions |
| 2430 | `[range(10)] \| .[1.5:3.5]` | Complex expressions |
| 2434 | `[range(10)] \| .[1.7:3.5]` | Complex expressions |
| 2438 | `[range(10)] \| .[1.7:4294967295]` | Complex expressions |
| 2442 | `[range(10)] \| .[1.7:-4294967296]` | Arithmetic |
| 2446 | `[[range(10)] \| .[1.1,1.5,1.7]]` | Complex expressions |
| 2450 | `[range(5)] \| .[1.1] = 5` | Complex expressions |
| 2454 | `[range(3)] \| .[nan:1]` | Complex expressions |
| 2458 | `[range(3)] \| .[1:nan]` | Complex expressions |
| 2462 | `[range(3)] \| .[nan]` | Complex expressions |
| 2466 | `try ([range(3)] \| .[nan] = 9) catch .` | Error handling |
| 2470 | `try ("foobar" \| .[1.5:3.5] = "xyz") c...` | Error handling |
| 2474 | `try ([range(10)] \| .[1.5:3.5] = ["xyz...` | Error handling |
| 2478 | `try ("foobar" \| .[1.5]) catch .` | Error handling |
| 2485 | `try ["ok", setpath([1]; 1)] catch ["k...` | Error handling |
| 2489 | `try fromjson catch .` | Error handling |
| 2495 | `try ltrimstr(1) catch "x", try rtrims...` | Error handling |
| 2500 | `try ltrimstr("x") catch "x", try rtri...` | Error handling |
| 2507 | `.[] as [$x, $y] \| try ["ok", ($x \| lt...` | Error handling |
| 2514 | `.[] as [$x, $y] \| try ["ok", ($x \| rt...` | Error handling |
| 2524 | `try ["OK", setpath([[1]]; 1)] catch [...` | Error handling |
| 2529 | `foreach .[] as $x (0, 1; . + $x)` | Arithmetic |
| 2539 | `strflocaltime("" \| ., @uri)` | Complex expressions |
| 2549 | `reduce range(9999) as $_ ([];[.]) \| t...` | Iteration |
| 2554 | `reduce range(10000) as $_ ([];[.]) \| ...` | Comparison |
| 2559 | `reduce range(10001) as $_ ([];[.]) \| ...` | Comparison |
