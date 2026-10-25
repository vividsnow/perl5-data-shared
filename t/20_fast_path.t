use strict;
use warnings;
use Test::More;
use Data::Shared qw(shared_compile sharedc_get sharedc_set sharedc_exists
                    sharedc_delete sharedc_incr sharedc_push sharedc_pop);

# The compiled accessors take a fast path once a binding is warm, so every case
# here calls through the SAME compiled path more than once: a single call only
# exercises the cold miss. t/07_compiled.t compiles a fresh path per call and so
# never reached the warm branch at all.
my $root = Data::Shared->new;
eval {
    $root->mount('cache', 'hashmap:ii', undef, 1024);
    $root->mount('jobs',  'queue:int',  undef, 64);
    1;
} or plan skip_all => "backend unavailable: $@";

my $cp = shared_compile('/cache/1');

# A caller that forwards with the ampersand form shares its own @_ with the
# callee, so the fast path must not modify @_ in place.
sub amp_get {
    my $v = &sharedc_get;
    return (scalar(@_), $v);
}
sub amp_set {
    my $v = &sharedc_set;
    return (scalar(@_), $v);
}

sharedc_set($root, $cp, 10);
for my $i (1 .. 3) {
    my ($argc, $v) = amp_get($root, $cp);
    is $v,    10, "ampersand-forwarded get returns the value (pass $i)";
    is $argc, 2,  "ampersand-forwarded get leaves the caller's \@_ intact (pass $i)";
}
for my $i (1 .. 3) {
    my ($argc) = amp_set($root, $cp, 20 + $i);
    is $argc, 3, "ampersand-forwarded set leaves the caller's \@_ intact (pass $i)";
    is sharedc_get($root, $cp), 20 + $i, "ampersand-forwarded set stored (pass $i)";
}

# Warm-path value checks: each verb runs twice through one compiled path.
my $ci = shared_compile('/cache/42');
for my $pass (1 .. 2) {
    sharedc_set($root, $ci, 100);
    is sharedc_get($root, $ci),    100, "set/get warm (pass $pass)";
    is sharedc_exists($root, $ci), 1,   "exists warm is 1 (pass $pass)";
    sharedc_incr($root, $ci);
    is sharedc_get($root, $ci),    101, "incr warm (pass $pass)";
    sharedc_delete($root, $ci);
    is sharedc_exists($root, $ci), 0,   "exists warm is 0 after delete (pass $pass)";
}

my $cq = shared_compile('/jobs');
for my $pass (1 .. 2) {
    sharedc_push($root, $cq, 7 + $pass);
    is sharedc_pop($root, $cq), 7 + $pass, "push/pop warm (pass $pass)";
}

# A smoke check that the fast path forwards a literal at all. It does not prove
# the adapter copies: no shipped backend writes its push argument, so this
# passes either way.
my $ok = eval { sharedc_push($root, $cq, 99); 1 };
ok $ok, 'pushing a literal does not die' or diag $@;
is sharedc_pop($root, $cq), 99, 'literal push round-trips';

done_testing;
