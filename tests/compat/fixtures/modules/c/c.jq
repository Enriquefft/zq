import "a" as foo;
import "d" as d;
import "d" as d2;
import "e" as e;
import "f" as f;
import "data" as $d;

def a: 0;
def c: foo::a + d::meh + e::e + f::f;
