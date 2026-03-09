const std = @import("std");
const parser_mod = @import("parser");
const query_mod = @import("query");
const types = @import("types");
const err = @import("error");

const Parser = parser_mod.Parser;
const CompiledQuery = query_mod.CompiledQuery;
const Value = types.Value;
const alloc = std.testing.allocator;

fn parseInput(input: []const u8) !types.Tape {
    var p = try Parser.init(alloc);
    defer p.deinit();
    const result = try p.feed(input, true);
    return switch (result) {
        .done => |tape| tape,
        .need_more => error.UnexpectedNeedMore,
    };
}

fn collectResults(query: *const CompiledQuery, tape: types.Tape) ![]Value {
    var it = try query.execute(tape, alloc);
    defer it.deinit();
    var results = std.ArrayList(Value).init(alloc);
    while (try it.next()) |v| try results.append(v);
    return results.toOwnedSlice();
}

test "jq:L8 true" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L12 false" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L16 null" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L20 1" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L25 -1" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L31 __" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L35 __" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L39 _x_-1___x_-.___x_-._abs_" {
    return error.SkipZigTest;
}

test "jq:L48 ." {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L54 _Aa_r_n_t_b_f_u03bc_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L58 ." {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L62 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L68 _inter___pol_ _ _ation___" {
    return error.SkipZigTest;
}

test "jq:L72 _text__json___1_.___csv__tsv___html___uri_.__urid___sh___..." {
    return error.SkipZigTest;
}

test "jq:L86 _base64" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L90 _base64d" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L94 _uri" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L98 _urid" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L102 _html __b___.___b__" {
    return error.SkipZigTest;
}

test "jq:L106 _.___tojson_fromjson_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L114 _a_ 1_" {
    return error.SkipZigTest;
}

test "jq:L118 _a_b__.d__.a_e_.b_" {
    return error.SkipZigTest;
}

test "jq:L122 __a__b__a___1_1___" {
    return error.SkipZigTest;
}

test "jq:L126 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L132 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L138 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L148 .foo" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L152 .foo _ .bar" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L156 .foo.bar" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L160 .foo_bar" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L164 .__foo__.bar" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L168 ._foo_._bar_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L172 .e0_ .E1_ .E-1_ .E_1" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L179 _.___.foo__" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L183 _.___.foo_.bar__" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L187 _.._" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L191 _.___.____" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L195 _.___._1_3___" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L200 map_try .a__ catch ._ try .a.__ catch ._ .a____ .a.____" {
    return error.SkipZigTest;
}

test "jq:L205 try __OK__ _.__ _ error__ catch __KO__ ._" {
    return error.SkipZigTest;
}

test "jq:L213 try _.foo_-1_ _ 0_ catch ." {
    return error.SkipZigTest;
}

test "jq:L217 try _.foo_-2_ _ 0_ catch ." {
    return error.SkipZigTest;
}

test "jq:L221 ._-1_ _ 5" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L225 ._-2_ _ 5" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L229 try _._999999999_ _ 0_ catch ." {
    return error.SkipZigTest;
}

test "jq:L237 .__" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L243 1_1" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L248 1_." {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L253 _._" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L257 __2__" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L261 ____" {
    return error.SkipZigTest;
}

test "jq:L265 _.___" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L269 __._1____._._____2_3___" {
    return error.SkipZigTest;
}

test "jq:L273 ___5_5_____._.___" {
    return error.SkipZigTest;
}

test "jq:L277 _x_ _1_2____x_3_ _ .x" {
    return error.SkipZigTest;
}

test "jq:L283 _._-4_-3_-2_-1_0_1_2_3__" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L287 _range_0_10__" {
    return error.SkipZigTest;
}

test "jq:L291 _range_0_1_3_4__" {
    return error.SkipZigTest;
}

test "jq:L295 _range_0_10_3__" {
    return error.SkipZigTest;
}

test "jq:L299 _range_0_10_-1__" {
    return error.SkipZigTest;
}

test "jq:L303 _range_0_-5_-1__" {
    return error.SkipZigTest;
}

test "jq:L307 _range_0_1_4_5_1_2__" {
    return error.SkipZigTest;
}

test "jq:L311 _while_._100_ ._2__" {
    return error.SkipZigTest;
}

test "jq:L315 __label _here _ .__ _ if ._1 then break _here else . end_..." {
    return error.SkipZigTest;
}

test "jq:L319 __label _here _ .__ _ if ._1 then break _here else . end_..." {
    return error.SkipZigTest;
}

test "jq:L323 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L329 _.____._1__until_._0_ _ 1_ _._0_ - 1_ ._1_ _ ._0____._1__" {
    return error.SkipZigTest;
}

test "jq:L333 _label _out _ foreach .__ as _item __3_ null__ if ._0_ _ ..." {
    return error.SkipZigTest;
}

test "jq:L337 _foreach range_5_ as _item _0_ _item__" {
    return error.SkipZigTest;
}

test "jq:L341 _foreach .__ as __i_ _j_ _0_ . _ _i - _j__" {
    return error.SkipZigTest;
}

test "jq:L345 _foreach .__ as _a__a_ _0_ . _ _a_ -.__" {
    return error.SkipZigTest;
}

test "jq:L349 _-foreach -.__ as _x _0_ . _ _x__" {
    return error.SkipZigTest;
}

test "jq:L353 _foreach .__ _ .__ as _i _0_ . _ _i__" {
    return error.SkipZigTest;
}

test "jq:L357 _foreach .__ as _x _0_ . _ _x_ as _x _ _x_" {
    return error.SkipZigTest;
}

test "jq:L361 _limit_3_ .____" {
    return error.SkipZigTest;
}

test "jq:L365 _limit_0_ error__" {
    return error.SkipZigTest;
}

test "jq:L369 _limit_1_ 1_ error__" {
    return error.SkipZigTest;
}

test "jq:L373 try limit_-1_ error_ catch ." {
    return error.SkipZigTest;
}

test "jq:L377 _skip_3_ .____" {
    return error.SkipZigTest;
}

test "jq:L381 _skip_0_2_3_4_ .____" {
    return error.SkipZigTest;
}

test "jq:L385 _skip_3_ .____" {
    return error.SkipZigTest;
}

test "jq:L389 try skip_-1_ error_ catch ." {
    return error.SkipZigTest;
}

test "jq:L393 nth_1_ 0_1_error__foo___" {
    return error.SkipZigTest;
}

test "jq:L397 _first_range_.___ last_range_.___" {
    return error.SkipZigTest;
}

test "jq:L401 _first_range_.___ last_range_.___" {
    return error.SkipZigTest;
}

test "jq:L405 _nth_0_5_9_10_15_ range_.___ try nth_-1_ range_.__ catch ._" {
    return error.SkipZigTest;
}

test "jq:L410 first_1_error__foo___" {
    return error.SkipZigTest;
}

test "jq:L420 _limit_5_7_ range_9___" {
    return error.SkipZigTest;
}

test "jq:L425 _nth_5_7_ range_9_0_-1___" {
    return error.SkipZigTest;
}

test "jq:L430 _range_0_1_2_4_3_2_2_3__" {
    return error.SkipZigTest;
}

test "jq:L435 _range_3_5__" {
    return error.SkipZigTest;
}

test "jq:L440 __index__________ rindex___________ indices__________" {
    return error.SkipZigTest;
}

test "jq:L445 join_________" {
    return error.SkipZigTest;
}

test "jq:L450 _.___join__a___" {
    return error.SkipZigTest;
}

test "jq:L455 flatten_3_2_1_" {
    return error.SkipZigTest;
}

test "jq:L466 _._3_2__ ._-5_4__ .__-2__ ._-2___ ._3_3__1___ ._10___" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L470 _._3_2__ ._-5_4__ .__-2__ ._-2___ ._3_3__1___ ._10___" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L474 del_._2_4__._0__._-2___" {
    return error.SkipZigTest;
}

test "jq:L478 ._2_4_ _ ____ __a___b___ __a___b___c___" {
    return error.SkipZigTest;
}

test "jq:L490 reduce range_65540_65536_-1_ as _i ____ .__i_ _ _i__._655..." {
    return error.SkipZigTest;
}

test "jq:L498 1 as _x _ 2 as _y _ __x__y__x_" {
    return error.SkipZigTest;
}

test "jq:L502 _1_2_3___ as _x _ __4_5_6_7___x__" {
    return error.SkipZigTest;
}

test "jq:L508 42 as _x _ . _ . _ . _ 432 _ _x _ 1" {
    return error.SkipZigTest;
}

test "jq:L512 1 _ 2 as _x _ -_x" {
    return error.SkipZigTest;
}

test "jq:L516 _x_ as _x _ _a___y_ as _y _ _x______y" {
    return error.SkipZigTest;
}

test "jq:L520 1 as _x _ __x__x__x as _x _ _x_" {
    return error.SkipZigTest;
}

test "jq:L524 _1_ _c_3_ d_4__ as __a_ _c__b_ b__c__ _ _a_ _b_ _c" {
    return error.SkipZigTest;
}

test "jq:L530 . as _as_ _kw_ _str__ _str_ __e___x___p___ _exp_ _ __kw_ ..." {
    return error.SkipZigTest;
}

test "jq:L534 .__ as __a_ _b_ _ __b_ _a_" {
    return error.SkipZigTest;
}

test "jq:L539 . as _i _ . as __i_ _ _i" {
    return error.SkipZigTest;
}

test "jq:L543 . as __i_ _ . as _i _ _i" {
    return error.SkipZigTest;
}

test "jq:L547 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L553 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L559 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L565 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L577 1_1" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L581 1_1" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L585 2-1" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L589 2-_-1_" {
    return error.SkipZigTest;
}

test "jq:L593 1e_0_0.001e3" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L597 ._4" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L601 ._null" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L605 null_." {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L609 .a_.b" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L613 _1_2_3_ _ _._" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L617 __a__1_ _ __b__2_ _ __c__3_" {
    return error.SkipZigTest;
}

test "jq:L621 _asdf_ _ _jkl__ _ . _ . _ ." {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L625 __u0000_u0020_u0000_ _ ." {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L629 42 - ." {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L633 _1_2_3_4_1_ - _._3_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L637 _-1 as _x _ 1__x_" {
    return error.SkipZigTest;
}

test "jq:L641 _10 _ 20_ 20 _ ._" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L645 1 _ 2 _ 2 _ 10 _ 2" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L649 _16 _ 4 _ 2_ 16 _ 4 _ 2_ 16 - 4 - 2_ 16 - 4 _ 2_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L653 1e-19 _ 1e-20 - 5e-21" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L657 1 _ 1e-17" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L661 9E999999999_ 9999999999E999999990_ 1E-999999999_ 0.000000..." {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L668 5E500000000 _ 5E-5000000000_ 10000E500000000 _ 10000E-500..." {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L674 _1e999999999_ 10e999999999_ _ _1e-1147483646_ 0.1e-114748..." {
    return error.SkipZigTest;
}

test "jq:L681 25 _ 7" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L685 49732 _ 472" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L689 __infinite_ -infinite_ _ _1_ -1_ infinite__" {
    return error.SkipZigTest;
}

test "jq:L693 _nan _ 1_ 1 _ nan _ isnan_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L697 1 _ tonumber _ __10_ _ tonumber_" {
    return error.SkipZigTest;
}

test "jq:L701 _123_u0000456_ _ try tonumber catch ." {
    return error.SkipZigTest;
}

test "jq:L705 map_toboolean_" {
    return error.SkipZigTest;
}

test "jq:L709 .__ _ try toboolean catch ." {
    return error.SkipZigTest;
}

test "jq:L720 _true_u0000x__ _false_u0000_ _ try toboolean catch ." {
    return error.SkipZigTest;
}

test "jq:L725 ___a__42__.object_10_.num_false_true_null__b___1_4__ _ ._..." {
    return error.SkipZigTest;
}

test "jq:L737 _.__ _ length_" {
    return error.SkipZigTest;
}

test "jq:L741 utf8bytelength" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L745 _.__ _ try utf8bytelength catch ._" {
    return error.SkipZigTest;
}

test "jq:L750 map_keys_" {
    return error.SkipZigTest;
}

test "jq:L754 _1_2_empty_3_empty_4_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L758 map_add_" {
    return error.SkipZigTest;
}

test "jq:L762 map_values_._1_" {
    return error.SkipZigTest;
}

test "jq:L766 _add_null__ add_range_range_10____ add_empty__ add_10_ran..." {
    return error.SkipZigTest;
}

test "jq:L771 .sum _ add_.arr___" {
    return error.SkipZigTest;
}

test "jq:L775 add___.____1__ _ keys" {
    return error.SkipZigTest;
}

test "jq:L784 def f_ . _ 1_ def g_ def g_ . _ 100_ f _ g _ f_ _f _ g__ g" {
    return error.SkipZigTest;
}

test "jq:L789 def f_ _1000_2000__ f" {
    return error.SkipZigTest;
}

test "jq:L794 def f_a_b_c_d_e_f__ _a_1_b_c_d_e_f__ f_._0__._1__._0__._0..." {
    return error.SkipZigTest;
}

test "jq:L798 def f_ 1_ def g_ f_ def f_ 2_ def g_ 3_ f_ def f_ g_ f_ g..." {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L803 def a_ 0_ . _ a" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L808 def f_a_b_c_d_e_f_g_h_i_j__ _j_i_h_g_f_e_d_c_b_a__ f_._0_..." {
    return error.SkipZigTest;
}

test "jq:L812 __1_2_ _ _4_5__" {
    return error.SkipZigTest;
}

test "jq:L816 true" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L820 null_1_null" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L826 _1_2_3_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L830 _.___floor_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L834 _.___sqrt_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L838 _add _ length_ as _m _ map__. - _m_ as _d _ _d _ _d_ _ ad..." {
    return error.SkipZigTest;
}

test "jq:L847 atan _ 4 _ 1000000_floor _ 1000000" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L851 __3.141592 _ 2_ _ _range_0_20_ _ 20__cos _ 1000000_floor ..." {
    return error.SkipZigTest;
}

test "jq:L855 __3.141592 _ 2_ _ _range_0_20_ _ 20__sin _ 1000000_floor ..." {
    return error.SkipZigTest;
}

test "jq:L860 def f_x__ x _ x_ f__.__ . _ _42__" {
    return error.SkipZigTest;
}

test "jq:L868 def f_ ._1_ def g_ f_ def f_ ._100_ def f_a__a_._11_ __g_..." {
    return error.SkipZigTest;
}

test "jq:L873 def id_x__x_ 2000 as _x _ def f_x__1 as _x _ id___x_ x_ x..." {
    return error.SkipZigTest;
}

test "jq:L878 def x_a_b__ a as _a _ b as _b _ _a _ _b_ def y__a__b__ _a..." {
    return error.SkipZigTest;
}

test "jq:L884 __20_10__1_0_ as _x _ def f_ _100_200_ as _y _ def g_ __x..." {
    return error.SkipZigTest;
}

test "jq:L889 def fac_ if . __ 1 then 1 else . _ _. - 1 _ fac_ end_ _._..." {
    return error.SkipZigTest;
}

test "jq:L899 reduce .__ as _x _0_ . _ _x_" {
    return error.SkipZigTest;
}

test "jq:L903 reduce .__ as __i_ _j__j__ _0_ . _ _i - _j_" {
    return error.SkipZigTest;
}

test "jq:L907 reduce __1_2_10__ _3_4_10____ as __i__j_ _0_ . _ _i _ _j_" {
    return error.SkipZigTest;
}

test "jq:L911 _-reduce -.__ as _x _0_ . _ _x__" {
    return error.SkipZigTest;
}

test "jq:L915 _reduce .__ _ .__ as _i _0_ . _ _i__" {
    return error.SkipZigTest;
}

test "jq:L919 reduce .__ as _x _0_ . _ _x_ as _x _ _x" {
    return error.SkipZigTest;
}

test "jq:L924 reduce . as _n _._ ._" {
    return error.SkipZigTest;
}

test "jq:L929 . as __a_ b_ __c_ __d___ _ __a_ _c_ _d_" {
    return error.SkipZigTest;
}

test "jq:L933 . as __a_ _b___c_ _d___ __a_ _b_ _c_ _d_" {
    return error.SkipZigTest;
}

test "jq:L938 .__ _ . as __a_ b_ __c_ __d___ ___ __a_ __b__ _e_ ___ _f ..." {
    return error.SkipZigTest;
}

test "jq:L945 .__ _ . as _a__a_ ___ _a__a_ ___ _a__a_ _ _a" {
    return error.SkipZigTest;
}

test "jq:L949 .__ as _a__a_ ___ _a__a_ ___ _a__a_ _ _a" {
    return error.SkipZigTest;
}

test "jq:L953 __3___4___5__6___ _ . as _a__a_ ___ _a__a_ ___ _a__a_ _ _a" {
    return error.SkipZigTest;
}

test "jq:L957 __3___4___5__6_ _ .__ as _a__a_ ___ _a__a_ ___ _a__a_ _ _a" {
    return error.SkipZigTest;
}

test "jq:L961 .__ _ . as _a__a_ ___ _a__a_ ___ _a _ _a" {
    return error.SkipZigTest;
}

test "jq:L968 .__ as _a__a_ ___ _a__a_ ___ _a _ _a" {
    return error.SkipZigTest;
}

test "jq:L975 __3___4___5__6___ _ . as _a__a_ ___ _a__a_ ___ _a _ _a" {
    return error.SkipZigTest;
}

test "jq:L982 __3___4___5__6_ _ .__ as _a__a_ ___ _a__a_ ___ _a _ _a" {
    return error.SkipZigTest;
}

test "jq:L989 .__ _ . as _a__a_ ___ _a ___ _a__a_ _ _a" {
    return error.SkipZigTest;
}

test "jq:L996 .__ as _a__a_ ___ _a ___ _a__a_ _ _a" {
    return error.SkipZigTest;
}

test "jq:L1003 __3___4___5__6___ _ . as _a__a_ ___ _a ___ _a__a_ _ _a" {
    return error.SkipZigTest;
}

test "jq:L1010 __3___4___5__6_ _ .__ as _a__a_ ___ _a ___ _a__a_ _ _a" {
    return error.SkipZigTest;
}

test "jq:L1017 .__ _ . as _a ___ _a__a_ ___ _a__a_ _ _a" {
    return error.SkipZigTest;
}

test "jq:L1024 .__ as _a ___ _a__a_ ___ _a__a_ _ _a" {
    return error.SkipZigTest;
}

test "jq:L1031 __3___4___5__6___ _ . as _a ___ _a__a_ ___ _a__a_ _ _a" {
    return error.SkipZigTest;
}

test "jq:L1038 __3___4___5__6_ _ .__ as _a ___ _a__a_ ___ _a__a_ _ _a" {
    return error.SkipZigTest;
}

test "jq:L1045 . as _dot_any__dot___not_" {
    return error.SkipZigTest;
}

test "jq:L1049 . as _dot_any__dot___not_" {
    return error.SkipZigTest;
}

test "jq:L1053 . as _dot_all__dot___._" {
    return error.SkipZigTest;
}

test "jq:L1057 . as _dot_all__dot___._" {
    return error.SkipZigTest;
}

test "jq:L1062 any_true_ error_ ._" {
    return error.SkipZigTest;
}

test "jq:L1066 all_false_ error_ ._" {
    return error.SkipZigTest;
}

test "jq:L1070 any_not_" {
    return error.SkipZigTest;
}

test "jq:L1074 all_not_" {
    return error.SkipZigTest;
}

test "jq:L1078 any_not_" {
    return error.SkipZigTest;
}

test "jq:L1082 all_not_" {
    return error.SkipZigTest;
}

test "jq:L1086 _any_all_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1090 _any_all_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1094 _any_all_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1098 _any_all_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1102 _any_all_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1110 path_.foo_0_1__" {
    return error.SkipZigTest;
}

test "jq:L1115 path_.__ _ select_._3__" {
    return error.SkipZigTest;
}

test "jq:L1119 path_._" {
    return error.SkipZigTest;
}

test "jq:L1123 try path_.a _ map_select_.b __ 0___ catch ." {
    return error.SkipZigTest;
}

test "jq:L1127 try path_.a _ map_select_.b __ 0__ _ ._0__ catch ." {
    return error.SkipZigTest;
}

test "jq:L1131 try path_.a _ map_select_.b __ 0__ _ .c_ catch ." {
    return error.SkipZigTest;
}

test "jq:L1135 try path_.a _ map_select_.b __ 0__ _ .___ catch ." {
    return error.SkipZigTest;
}

test "jq:L1139 path_.a_path_.b__0___" {
    return error.SkipZigTest;
}

test "jq:L1143 _paths_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1147 __foo__1_ as _p _ getpath__p__ setpath__p_ 20__ delpaths_..." {
    return error.SkipZigTest;
}

test "jq:L1153 map_getpath__2____ map_setpath__2__ 42___ map_delpaths___..." {
    return error.SkipZigTest;
}

test "jq:L1159 map_delpaths___0__foo_____" {
    return error.SkipZigTest;
}

test "jq:L1163 __foo__1_ as _p _ getpath__p__ setpath__p_ 20__ delpaths_..." {
    return error.SkipZigTest;
}

test "jq:L1169 delpaths___-200___" {
    return error.SkipZigTest;
}

test "jq:L1173 try delpaths_0_ catch ." {
    return error.SkipZigTest;
}

test "jq:L1177 del_.__ del_empty__ del__.foo_.bar_.baz_ _ ._2_3_0___ del..." {
    return error.SkipZigTest;
}

test "jq:L1184 del_._1__ ._-6__ ._2__ ._-3_9__" {
    return error.SkipZigTest;
}

test "jq:L1188 del_._nan__" {
    return error.SkipZigTest;
}

test "jq:L1192 del_._nan_nan__" {
    return error.SkipZigTest;
}

test "jq:L1197 setpath__-1__ 1_" {
    return error.SkipZigTest;
}

test "jq:L1201 pick_.a.b.c_" {
    return error.SkipZigTest;
}

test "jq:L1205 pick_first_" {
    return error.SkipZigTest;
}

test "jq:L1209 pick_first_first_" {
    return error.SkipZigTest;
}

test "jq:L1214 try pick_last_ catch ." {
    return error.SkipZigTest;
}

test "jq:L1221 .message _ _goodbye_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1225 .foo _ .bar" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1229 .foo __ ._1" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1233 .__ __ 2_ .__ __ 2_ .__ -_ 2_ .__ __ 2_ .__ __2" {
    return error.SkipZigTest;
}

test "jq:L1241 _.__ _ 7_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1245 .foo __ .foo" {
    return error.SkipZigTest;
}

test "jq:L1249 ._0_.a __ __old__._ _new___._1__" {
    return error.SkipZigTest;
}

test "jq:L1253 def inc_x__ x __ ._1_ inc_.__.a_" {
    return error.SkipZigTest;
}

test "jq:L1258 .__ _ try _getpath___a__0__b___ __ 5_ catch ." {
    return error.SkipZigTest;
}

test "jq:L1270 _.__ _ select_. __ 2__ __ empty" {
    return error.SkipZigTest;
}

test "jq:L1274 .__ __ select_. _ 2 __ 0_" {
    return error.SkipZigTest;
}

test "jq:L1278 .foo_1_4_2_3_ __ empty" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1282 ._2__3_ _ 1" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1286 .foo_2_.bar _ 1" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1290 try __map_select_.a __ 1____.b_ _ 10_ catch ." {
    return error.SkipZigTest;
}

test "jq:L1294 try __map_select_.a __ 1____.a_ __ ._1_ catch ." {
    return error.SkipZigTest;
}

test "jq:L1298 def x_ ._1_2__ x_10" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1302 try _def x_ reverse_ x_10_ catch ." {
    return error.SkipZigTest;
}

test "jq:L1306 .__ _ 1" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1314 _.__ _ if .foo then _yep_ else _nope_ end_" {
    return error.SkipZigTest;
}

test "jq:L1318 _.__ _ if .baz then _strange_ elif .foo then _yep_ else _..." {
    return error.SkipZigTest;
}

test "jq:L1322 _if 1_null_2 then 3 else 4 end_" {
    return error.SkipZigTest;
}

test "jq:L1326 _if empty then 3 else 4 end_" {
    return error.SkipZigTest;
}

test "jq:L1330 _if 1 then 3_4 else 5 end_" {
    return error.SkipZigTest;
}

test "jq:L1334 _if null then 3 else 5_6 end_" {
    return error.SkipZigTest;
}

test "jq:L1338 _if true then 3 end_" {
    return error.SkipZigTest;
}

test "jq:L1342 _if false then 3 end_" {
    return error.SkipZigTest;
}

test "jq:L1346 _if false then 3 else . end_" {
    return error.SkipZigTest;
}

test "jq:L1350 _if false then 3 elif false then 4 end_" {
    return error.SkipZigTest;
}

test "jq:L1354 _if false then 3 elif false then 4 else . end_" {
    return error.SkipZigTest;
}

test "jq:L1358 _-if true then 1 else 2 end_" {
    return error.SkipZigTest;
}

test "jq:L1362 _x_ if true then 1 else 2 end_" {
    return error.SkipZigTest;
}

test "jq:L1366 if true then _._ else . end __" {
    return error.SkipZigTest;
}

test "jq:L1370 _.__ _ _.foo__ __ .bar__" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1374 .__ ___ ._0_" {
    return error.SkipZigTest;
}

test "jq:L1378 .__ _ _._0_ and ._1__ ._0_ or ._1__" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1385 _.__ _ not_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1390 _10 _ 0_ 10 _ 10_ 10 _ 20_ 10 _ 0_ 10 _ 10_ 10 _ 20_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1394 _10 __ 0_ 10 __ 10_ 10 __ 20_ 10 __ 0_ 10 __ 10_ 10 __ 20_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1399 _ 10 __ 10_ 10 __ 10_ 10 __ 11_ 10 __ 11_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1403 __hello_ __ _hello__ _hello_ __ _hello__ _hello_ __ _worl..." {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1407 __1_2_3_ __ _1_2_3__ _1_2_3_ __ _1_2_3__ _1_2_3_ __ _4_5_..." {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1411 ___foo__42_ __ __foo__42____foo__42_ __ __foo__42__ __foo..." {
    return error.SkipZigTest;
}

test "jq:L1416 ___foo___1_2___bar__18___world___ __ __foo___1_2___bar__1..." {
    return error.SkipZigTest;
}

test "jq:L1421 ___foo_ _ contains__foo____ __foobar_ _ contains__foo____..." {
    return error.SkipZigTest;
}

test "jq:L1426 _contains_____ contains___u0000___" {
    return error.SkipZigTest;
}

test "jq:L1430 _contains_____ contains__a___ contains__ab___ contains__c..." {
    return error.SkipZigTest;
}

test "jq:L1434 _contains__cd___ contains__b_u0000___ contains__ab_u0000___" {
    return error.SkipZigTest;
}

test "jq:L1438 _contains__b_u0000c___ contains__b_u0000cd___ contains__b..." {
    return error.SkipZigTest;
}

test "jq:L1442 _contains______ contains___u0000____ contains___u0000what___" {
    return error.SkipZigTest;
}

test "jq:L1448 _.___try if . __ 0 then error__foo__ elif . __ 1 then .a ..." {
    return error.SkipZigTest;
}

test "jq:L1452 _.____.a_ .a___" {
    return error.SkipZigTest;
}

test "jq:L1456 __.____.a_.a____" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1460 _if error then 1 else 2 end__" {
    return error.SkipZigTest;
}

test "jq:L1464 try error_0_ __ 1" {
    return error.SkipZigTest;
}

test "jq:L1468 1_ try error_2__ 3" {
    return error.SkipZigTest;
}

test "jq:L1473 1 _ try 2 catch 3 _ 4" {
    return error.SkipZigTest;
}

test "jq:L1477 _-try ._" {
    return error.SkipZigTest;
}

test "jq:L1481 try -._ catch ." {
    return error.SkipZigTest;
}

test "jq:L1485 _x_ try 1_ y_ try error catch 2_ z_ if true then 3 end_" {
    return error.SkipZigTest;
}

test "jq:L1489 _x_ 1 _ 2_ y_ false or true_ z_ null __ 3_" {
    return error.SkipZigTest;
}

test "jq:L1493 .__ _ try error catch ." {
    return error.SkipZigTest;
}

test "jq:L1499 try error_______loc_____ catch ." {
    return error.SkipZigTest;
}

test "jq:L1504 _.___startswith__foo___" {
    return error.SkipZigTest;
}

test "jq:L1508 _.___endswith__foo___" {
    return error.SkipZigTest;
}

test "jq:L1512 _.__ _ split___ ___" {
    return error.SkipZigTest;
}

test "jq:L1516 split____" {
    return error.SkipZigTest;
}

test "jq:L1520 _.___ltrimstr__foo___" {
    return error.SkipZigTest;
}

test "jq:L1524 _.___rtrimstr__foo___" {
    return error.SkipZigTest;
}

test "jq:L1528 _.___trimstr__foo___" {
    return error.SkipZigTest;
}

test "jq:L1532 _.___ltrimstr_____" {
    return error.SkipZigTest;
}

test "jq:L1536 _.___rtrimstr_____" {
    return error.SkipZigTest;
}

test "jq:L1540 _.___trimstr_____" {
    return error.SkipZigTest;
}

test "jq:L1544 __index______ rindex_______ indices______" {
    return error.SkipZigTest;
}

test "jq:L1548 _ index__aba___ rindex__aba___ indices__aba__ _" {
    return error.SkipZigTest;
}

test "jq:L1554 map_trim__ map_ltrim__ map_rtrim_" {
    return error.SkipZigTest;
}

test "jq:L1560 trim_ ltrim_ rtrim" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1566 try trim catch ._ try ltrim catch ._ try rtrim catch ." {
    return error.SkipZigTest;
}

test "jq:L1572 indices_1_" {
    return error.SkipZigTest;
}

test "jq:L1576 indices__1_2__" {
    return error.SkipZigTest;
}

test "jq:L1580 indices__1_2__" {
    return error.SkipZigTest;
}

test "jq:L1584 indices___ __" {
    return error.SkipZigTest;
}

test "jq:L1588 index_____" {
    return error.SkipZigTest;
}

test "jq:L1592 .__rindex__x___" {
    return error.SkipZigTest;
}

test "jq:L1596 indices__o__" {
    return error.SkipZigTest;
}

test "jq:L1600 indices__o__" {
    return error.SkipZigTest;
}

test "jq:L1604 _.___split______" {
    return error.SkipZigTest;
}

test "jq:L1608 _.___split___ ___" {
    return error.SkipZigTest;
}

test "jq:L1612 _.__ _ 3_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1616 _.__ _ _abc__" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1620 _. _ _nan_-nan__" {
    return error.SkipZigTest;
}

test "jq:L1624 . _ 100000 _ _.__10__._-10___" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1628 . _ 1000000000" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1632 try _. _ 1000000000_ catch ." {
    return error.SkipZigTest;
}

test "jq:L1636 _.__ _ ____" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1640 _.__ _ __ __" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1644 map_._1_ as _needle _ ._0_ _ contains__needle__" {
    return error.SkipZigTest;
}

test "jq:L1648 map_._1_ as _needle _ ._0_ _ contains__needle__" {
    return error.SkipZigTest;
}

test "jq:L1652 ___foo_ 12_ bar_13_ _ contains__foo_ 12____ __foo_ 12_ _ ..." {
    return error.SkipZigTest;
}

test "jq:L1656 _foo_ _baz_ 12_ blap_ _bar_ 13___ bar_ 14_ _ contains__ba..." {
    return error.SkipZigTest;
}

test "jq:L1660 _foo_ _baz_ 12_ blap_ _bar_ 13___ bar_ 14_ _ contains__ba..." {
    return error.SkipZigTest;
}

test "jq:L1664 sort" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1668 _sort_by_.b_ _ sort_by_.a___ sort_by_.a_ .b__ sort_by_.b_..." {
    return error.SkipZigTest;
}

test "jq:L1676 unique" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1680 unique" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1684 _min_ max_ min_by_._1___ max_by_._1___ min_by_._2___ max_..." {
    return error.SkipZigTest;
}

test "jq:L1688 _min_max_min_by_.__max_by_.__" {
    return error.SkipZigTest;
}

test "jq:L1692 .foo_.baz_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1696 .__ _ .error _ _no_ it_s OK_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1700 __a_1__ _ .__ _ .a_999" {
    return error.SkipZigTest;
}

test "jq:L1704 to_entries" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1708 from_entries" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1712 with_entries_.key __ _KEY__ _ ._" {
    return error.SkipZigTest;
}

test "jq:L1716 map_has__foo___" {
    return error.SkipZigTest;
}

test "jq:L1720 map_has_2__" {
    return error.SkipZigTest;
}

test "jq:L1724 has_nan_" {
    return error.SkipZigTest;
}

test "jq:L1728 keys" {
    return error.SkipZigTest;
}

test "jq:L1732 ___._" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1736 map__1_2__0_.__" {
    return error.SkipZigTest;
}

test "jq:L1742 __k__ __a__ 1_ _b__ 2__ _ ." {
    return error.SkipZigTest;
}

test "jq:L1746 __k__ __a__ 1_ _b__ 2__ _hello__ __x__ 1__ _ ." {
    return error.SkipZigTest;
}

test "jq:L1750 __k__ __a__ 1_ _b__ 2__ _hello__ 1_ _ ." {
    return error.SkipZigTest;
}

test "jq:L1754 __a__ __b__ 1__ _c__ __d__ 2__ _e__ 5_ _ ." {
    return error.SkipZigTest;
}

test "jq:L1758 _.___arrays_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1762 _.___objects_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1766 _.___iterables_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1770 _.___scalars_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1774 _.___values_" {
    return error.SkipZigTest;
}

test "jq:L1778 _.___booleans_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1782 _.___nulls_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1786 flatten" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1790 flatten_0_" {
    return error.SkipZigTest;
}

test "jq:L1794 flatten_2_" {
    return error.SkipZigTest;
}

test "jq:L1798 flatten_2_" {
    return error.SkipZigTest;
}

test "jq:L1802 try flatten_-1_ catch ." {
    return error.SkipZigTest;
}

test "jq:L1806 transpose" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1810 transpose" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1814 ascii_upcase" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1818 bsearch_0_1_2_3_4_" {
    return error.SkipZigTest;
}

test "jq:L1826 bsearch__x_1__" {
    return error.SkipZigTest;
}

test "jq:L1830 try __OK__ bsearch_0__ catch __KO__._" {
    return error.SkipZigTest;
}

test "jq:L1834 strftime___Y-_m-_dT_H__M__SZ__" {
    return error.SkipZigTest;
}

test "jq:L1838 strftime___A_ _B _d_ _Y__" {
    return error.SkipZigTest;
}

test "jq:L1842 strftime___Y-_m-_dT_H__M__SZ__" {
    return error.SkipZigTest;
}

test "jq:L1846 mktime" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1850 gmtime" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1854 gmtime_5_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1859 try strftime___Y-_m-_dT_H__M__SZ__ catch ." {
    return error.SkipZigTest;
}

test "jq:L1863 try strflocaltime___Y-_m-_dT_H__M__SZ__ catch ." {
    return error.SkipZigTest;
}

test "jq:L1867 try mktime catch ." {
    return error.SkipZigTest;
}

test "jq:L1872 try __OK__ strftime_____ catch __KO__ ._" {
    return error.SkipZigTest;
}

test "jq:L1876 try __OK__ strflocaltime_____ catch __KO__ ._" {
    return error.SkipZigTest;
}

test "jq:L1880 _strptime___Y-_m-_dT_H__M__SZ____._mktime__" {
    return error.SkipZigTest;
}

test "jq:L1886 last_range_365 _ 67____1970-03-01T01_02_03Z__strptime___Y..." {
    return error.SkipZigTest;
}

test "jq:L1891 import _a_ as foo_ import _b_ as bar_ def fooa_ foo__a_ _..." {
    return error.SkipZigTest;
}

test "jq:L1895 import _c_ as foo_ _foo__a_ foo__c_" {
    return error.SkipZigTest;
}

test "jq:L1899 include _c__ _a_ c_" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1903 import _data_ as _e_ import _data_ as _d_ __d__.this__e__..." {
    return error.SkipZigTest;
}

test "jq:L1908 import _data_ as _a_ import _data_ as _b_ def f_ __a_ _b__ f" {
    return error.SkipZigTest;
}

test "jq:L1912 include _shadow1__ e" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1916 include _shadow1__ include _shadow2__ e" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1920 import _shadow1_ as f_ import _shadow2_ as f_ import _sha..." {
    return error.SkipZigTest;
}

test "jq:L1924 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1930 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1936 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1942 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1948 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1954 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1960 modulemeta" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1964 modulemeta _ .deps _ length" {
    return error.SkipZigTest;
}

test "jq:L1968 modulemeta _ .defs _ length" {
    return error.SkipZigTest;
}

test "jq:L1972 __FAIL IGNORE MSG" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1978 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L1984 import _test_bind_order_ as check_ check__check" {
    return error.SkipZigTest;
}

test "jq:L1988 try -. catch ." {
    return error.SkipZigTest;
}

test "jq:L1992 try _.-._ catch ." {
    return error.SkipZigTest;
}

test "jq:L1996 _x_ _ range_0_ 12_ 2_ _ ___ _ 8 _ try -. catch ." {
    return error.SkipZigTest;
}

test "jq:L2005 try _. _ _x__ catch . __ if have_decnum then _number _123..." {
    return error.SkipZigTest;
}

test "jq:L2009 join_____" {
    return error.SkipZigTest;
}

test "jq:L2013 .__ _ join_____" {
    return error.SkipZigTest;
}

test "jq:L2020 .__ _ join_____" {
    return error.SkipZigTest;
}

test "jq:L2025 try join_____ catch ." {
    return error.SkipZigTest;
}

test "jq:L2029 try join_____ catch ." {
    return error.SkipZigTest;
}

test "jq:L2033 _if_0_and_1_or_2_then_3_else_4_elif_5_end_6_as_7_def_8_re..." {
    return error.SkipZigTest;
}

test "jq:L2037 try _1_._ catch ." {
    return error.SkipZigTest;
}

test "jq:L2041 try _1_0_ catch ." {
    return error.SkipZigTest;
}

test "jq:L2045 try _0_0_ catch ." {
    return error.SkipZigTest;
}

test "jq:L2049 try _1_._ catch ." {
    return error.SkipZigTest;
}

test "jq:L2053 try _1_0_ catch ." {
    return error.SkipZigTest;
}

test "jq:L2058 _range_-52_52_1__ as _powers _ __powers___pow_2_.__log2_r..." {
    return error.SkipZigTest;
}

test "jq:L2062 _range_-99_2_99_2_1__ as _orig _ __orig___pow_2_.__log2_ ..." {
    return error.SkipZigTest;
}

test "jq:L2065 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L2071 __FAIL" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L2077 _.____ _ 0__" {
    return error.SkipZigTest;
}

test "jq:L2080 INDEX_range_5___._ _foo__.____ ._0__" {
    return error.SkipZigTest;
}

test "jq:L2084 JOIN___0___0__abc____1___1__bcd____2___2__def____3___3__e..." {
    return error.SkipZigTest;
}

test "jq:L2088 range_5_10__IN_range_10__" {
    return error.SkipZigTest;
}

test "jq:L2096 range_5_13__IN_range_0_10_3__" {
    return error.SkipZigTest;
}

test "jq:L2107 range_10_12__IN_range_10__" {
    return error.SkipZigTest;
}

test "jq:L2112 IN_range_10_20__ range_10__" {
    return error.SkipZigTest;
}

test "jq:L2116 IN_range_5_20__ range_10__" {
    return error.SkipZigTest;
}

test "jq:L2121 _.a as _x _ .b_ _ _b_" {
    return error.SkipZigTest;
}

test "jq:L2126 _.. _ select_type __ _object_ and has__b__ and _.b _ type..." {
    return error.SkipZigTest;
}

test "jq:L2130 isempty_empty_" {
    return error.SkipZigTest;
}

test "jq:L2134 isempty_range_3__" {
    return error.SkipZigTest;
}

test "jq:L2138 isempty_1_error__foo___" {
    return error.SkipZigTest;
}

test "jq:L2143 index____" {
    return error.SkipZigTest;
}

test "jq:L2148 builtins_length _ 10" {
    return error.SkipZigTest;
}

test "jq:L2152 _-1__IN_builtins__ _ ____._1__" {
    return error.SkipZigTest;
}

test "jq:L2156 all_builtins__ _ ____ ._1__tonumber __ 0_" {
    return error.SkipZigTest;
}

test "jq:L2160 builtins_any_.__1_ __ ____" {
    return error.SkipZigTest;
}

test "jq:L2181 map_. __ 1_" {
    return error.SkipZigTest;
}

test "jq:L2187 ._0_ _ tostring _ . __ if have_decnum then _1391186036643..." {
    return error.SkipZigTest;
}

test "jq:L2191 .x _ tojson _ . __ if have_decnum then _13911860366432393..." {
    return error.SkipZigTest;
}

test "jq:L2195 _13911860366432393 __ 13911860366432392_ _ . __ if have_d..." {
    return error.SkipZigTest;
}

test "jq:L2202 . - 10" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L2206 ._0_ - 10" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L2210 .x - 10" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L2215 -. _ tojson __ if have_decnum then _-13911860366432393_ e..." {
    return error.SkipZigTest;
}

test "jq:L2219 -. _ tojson __ if have_decnum then _0.1234567890123456789..." {
    return error.SkipZigTest;
}

test "jq:L2223 _1E_1000_-1E_1000 _ tojson_ __ if have_decnum then __1E_1..." {
    return error.SkipZigTest;
}

test "jq:L2227 . __ try . catch ." {
    return error.SkipZigTest;
}

test "jq:L2232 .__ as _n _ _n_0 _ _._ tostring_ . __ _n_" {
    return error.SkipZigTest;
}

test "jq:L2241 abs" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L2245 map_abs_" {
    return error.SkipZigTest;
}

test "jq:L2249 map_fabs_" {
    return error.SkipZigTest;
}

test "jq:L2253 map_abs __ length_ _ unique" {
    return error.SkipZigTest;
}

test "jq:L2258 map_abs_" {
    return error.SkipZigTest;
}

test "jq:L2262 _1E_1000_-1E_1000 _ abs _ tojson_ _ unique __ if have_dec..." {
    return error.SkipZigTest;
}

test "jq:L2266 _1E_1000_-1E_1000 _ length _ tojson_ _ unique __ if have_..." {
    return error.SkipZigTest;
}

test "jq:L2272 123 as _label _ _label" {
    return error.SkipZigTest;
}

test "jq:L2276 _ label _if _ range_10_ _ ._ _select_. __ 5_ _ break _if_ _" {
    return error.SkipZigTest;
}

test "jq:L2280 reduce .__ as _then _4 as _else _ _else_ . as _elif _ . _..." {
    return error.SkipZigTest;
}

test "jq:L2284 1 as _foreach _ 2 as _and _ 3 as _or _ _ _foreach_ _and_ ..." {
    return error.SkipZigTest;
}

test "jq:L2288 _ foreach .__ as _try _1 as _catch _ _catch - 1_ . _ _try..." {
    return error.SkipZigTest;
}

test "jq:L2295 _ a_ ___loc___ c _" {
    return error.SkipZigTest;
}

test "jq:L2299 1 as _x _ _2_ as _y _ _3_ as _z _ _ _x_ as_ _y_ 4_ __z__ ..." {
    return error.SkipZigTest;
}

test "jq:L2306 fromjson _ isnan" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L2310 tojson _ fromjson" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L2315 .__ _ try _fromjson _ isnan_ catch ." {
    return error.SkipZigTest;
}

test "jq:L2328 try input catch ." {
    return error.SkipZigTest;
}

test "jq:L2332 debug" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L2337 _foo_ _ try __try . catch _caught too much__ _ error_ cat..." {
    return error.SkipZigTest;
}

test "jq:L2341 .____try _if .___hi_ then . else error end_ catch empty_ ..." {
    return error.SkipZigTest;
}

test "jq:L2345 try ___hi___ho___.____try . catch _if .___ho_ then _BROKE..." {
    return error.SkipZigTest;
}

test "jq:L2350 .____try . catch _if .___ho_ then _BROKEN__error else emp..." {
    return error.SkipZigTest;
}

test "jq:L2354 try _try error catch _inner catch __.___ catch _outer cat..." {
    return error.SkipZigTest;
}

test "jq:L2358 try __try error catch _inner catch __.____error_ catch _o..." {
    return error.SkipZigTest;
}

test "jq:L2363 first_.__.__" {
    return error.SkipZigTest;
}

test "jq:L2368 _foo_ _bar__ _ .foo __ ._" {
    return error.SkipZigTest;
}

test "jq:L2373 . __ try 2" {
    return error.SkipZigTest;
}

test "jq:L2377 . __ try 2 catch 3" {
    return error.SkipZigTest;
}

test "jq:L2381 .__ __ try tonumber" {
    return error.SkipZigTest;
}

test "jq:L2386 any_keys___tostring__true_" {
    return error.SkipZigTest;
}

test "jq:L2394 implode_explode" {
    return error.SkipZigTest; // TODO: implement
}

test "jq:L2398 map_try implode catch ._" {
    return error.SkipZigTest;
}

test "jq:L2402 try 0_implode_ catch ." {
    return error.SkipZigTest;
}

test "jq:L2407 walk_._" {
    return error.SkipZigTest;
}

test "jq:L2411 walk_1_" {
    return error.SkipZigTest;
}

test "jq:L2416 _walk_._1__" {
    return error.SkipZigTest;
}

test "jq:L2421 walk_select_IN____ ___ _ not__" {
    return error.SkipZigTest;
}

test "jq:L2426 _range_10__ _ ._1.2_3.5_" {
    return error.SkipZigTest;
}

test "jq:L2430 _range_10__ _ ._1.5_3.5_" {
    return error.SkipZigTest;
}

test "jq:L2434 _range_10__ _ ._1.7_3.5_" {
    return error.SkipZigTest;
}

test "jq:L2438 _range_10__ _ ._1.7_4294967295_" {
    return error.SkipZigTest;
}

test "jq:L2442 _range_10__ _ ._1.7_-4294967296_" {
    return error.SkipZigTest;
}

test "jq:L2446 __range_10__ _ ._1.1_1.5_1.7__" {
    return error.SkipZigTest;
}

test "jq:L2450 _range_5__ _ ._1.1_ _ 5" {
    return error.SkipZigTest;
}

test "jq:L2454 _range_3__ _ ._nan_1_" {
    return error.SkipZigTest;
}

test "jq:L2458 _range_3__ _ ._1_nan_" {
    return error.SkipZigTest;
}

test "jq:L2462 _range_3__ _ ._nan_" {
    return error.SkipZigTest;
}

test "jq:L2466 try __range_3__ _ ._nan_ _ 9_ catch ." {
    return error.SkipZigTest;
}

test "jq:L2470 try __foobar_ _ ._1.5_3.5_ _ _xyz__ catch ." {
    return error.SkipZigTest;
}

test "jq:L2474 try __range_10__ _ ._1.5_3.5_ _ __xyz___ catch ." {
    return error.SkipZigTest;
}

test "jq:L2478 try __foobar_ _ ._1.5__ catch ." {
    return error.SkipZigTest;
}

test "jq:L2485 try __ok__ setpath__1__ 1__ catch __ko__ ._" {
    return error.SkipZigTest;
}

test "jq:L2489 try fromjson catch ." {
    return error.SkipZigTest;
}

test "jq:L2495 try ltrimstr_1_ catch _x__ try rtrimstr_1_ catch _x_ _ _ok_" {
    return error.SkipZigTest;
}

test "jq:L2500 try ltrimstr__x__ catch _x__ try rtrimstr__x__ catch _x_ ..." {
    return error.SkipZigTest;
}

test "jq:L2507 .__ as __x_ _y_ _ try __ok__ __x _ ltrimstr__y___ catch _..." {
    return error.SkipZigTest;
}

test "jq:L2514 .__ as __x_ _y_ _ try __ok__ __x _ rtrimstr__y___ catch _..." {
    return error.SkipZigTest;
}

test "jq:L2524 try __OK__ setpath___1___ 1__ catch __KO__ ._" {
    return error.SkipZigTest;
}

test "jq:L2529 foreach .__ as _x _0_ 1_ . _ _x_" {
    return error.SkipZigTest;
}

test "jq:L2539 strflocaltime___ _ ._ _uri_" {
    return error.SkipZigTest;
}

test "jq:L2549 reduce range_9999_ as __ _____.__ _ tojson _ fromjson _ f..." {
    return error.SkipZigTest;
}

test "jq:L2554 reduce range_10000_ as __ _____.__ _ tojson _ try _fromjs..." {
    return error.SkipZigTest;
}

test "jq:L2559 reduce range_10001_ as __ _____.__ _ tojson _ contains___..." {
    return error.SkipZigTest;
}

