use strict;
use warnings;
use Test::More;
use Data::Shared::Adapter::Map ();
use Data::Shared::Adapter::Set ();
use Data::Shared::Adapter::Indexed ();
use Data::Shared::Adapter::Queue ();
use Data::Shared::Adapter::Sketch ();
use Data::Shared::Adapter::Sync ();

package MockHandle {
    sub new { bless { v => {}, log => [] }, shift }
    sub get { my ($s, $k) = @_; return $s->{v}{$k} }
    sub put { my ($s, $k, $val) = @_; $s->{v}{$k} = $val; return $val }
    sub set { my $s = shift; return $s->put(@_) }
    sub remove { my ($s, $k) = @_; return delete $s->{v}{$k} }
    sub exists { my ($s, $k) = @_; return exists $s->{v}{$k} ? 1 : 0 }
    sub incr { my ($s, $k) = @_; return ++$s->{v}{$k} }
    sub incr_by { my ($s, $k, $d) = @_; return $s->{v}{$k} += $d }
    sub score { my ($s, $k) = @_; return $s->{v}{$k} }
    sub add { my ($s, $k, $val) = @_; $s->{v}{$k} = defined $val ? $val : ($s->{v}{$k} || 0) + 1; return $s->{v}{$k} }
    sub estimate { my ($s, $k) = @_; return $s->{v}{$k} || 0 }
    sub point { my ($s, @idx) = @_; return $s->{v}{join ',', @idx} }
    sub update { my ($s, @a) = @_; return $a[-1] }
    sub push { my ($s, @a) = @_; push @{ $s->{q} }, @a; return 1 }
    sub pop { my ($s) = @_; return shift @{ $s->{q} } }
    sub pair { return wantarray ? (7, 42) : 42 }
    sub publish { my ($s, @a) = @_; return $s->push(@a) }
}

package main;

sub check_adapter {
    my ($adapter, $entry, $verb, $rest, $args, $want, $label) = @_;
    my $h = MockHandle->new;
    $h->{v}{k} = 10;
    $h->{v}{'1,2'} = 7;
    my $via_perform = eval { $adapter->perform($verb, $h, $entry, $rest, @$args) };
    my $perform_err = $@;
    my $h2 = MockHandle->new; $h2->{v}{k} = 10; $h2->{v}{'1,2'} = 7;
    my $code = $adapter->make_verb($verb, $h2, $entry);
    ok $code, "$label make_verb" or diag $perform_err;
    my $via_code = $code ? $code->($rest, @$args) : undef;
    my $h3 = MockHandle->new; $h3->{v}{k} = 10; $h3->{v}{'1,2'} = 7;
    my $bound = $adapter->make_bound($verb, $h3, $entry, $rest);
    ok $bound, "$label make_bound" or diag $perform_err;
    my $via_bound = $bound ? $bound->(@$args) : undef;
    is $via_perform, $want, "$label perform";
    is $via_code, $want, "$label verb code";
    is $via_bound, $want, "$label bound";
}

my $map_entry = { key => 'mock', verbs => { get => 'get', set => 'put', delete => 'remove', exists => 'exists', incr => 'incr' } };
check_adapter('Data::Shared::Adapter::Map', $map_entry, 'get', ['k'], [], 10, 'map get');
check_adapter('Data::Shared::Adapter::Map', $map_entry, 'exists', ['k'], [], 1, 'map exists');
check_adapter('Data::Shared::Adapter::Map', $map_entry, 'incr', ['k'], [], 11, 'map incr');
check_adapter('Data::Shared::Adapter::Map', $map_entry, 'incr', ['k'], [5], 15, 'map incr_by');
my $map_code_entry = { key => 'mock', verbs => { set => sub { my ($h, $k, $v) = @_; return $h->put($k, $v * 2) } } };
check_adapter('Data::Shared::Adapter::Map', $map_code_entry, 'set', ['k'], [21], 42, 'map coderef set');
check_adapter('Data::Shared::Adapter::Set', { key => 'mock', verbs => { get => 'score', set => 'add' } }, 'get', ['k'], [], 10, 'set get');
check_adapter('Data::Shared::Adapter::Sketch', { key => 'mock', verbs => { get => 'estimate' } }, 'get', ['k'], [], 10, 'sketch get');
check_adapter('Data::Shared::Adapter::Indexed', { key => 'mock', verbs => { get => 'point', set => 'set' } }, 'get', ['1', '2'], [], 7, 'indexed get');
check_adapter('Data::Shared::Adapter::Set', { key => 'mock', verbs => { set => 'add', incr => 'incr' } }, 'set', ['k'], [99], 99, 'set set');
check_adapter('Data::Shared::Adapter::Set', { key => 'mock', verbs => { set => 'add', incr => 'incr' } }, 'incr', ['k'], [], 11, 'set incr');
check_adapter('Data::Shared::Adapter::Sketch', { key => 'mock', verbs => { set => sub { my ($h, $k, $v) = @_; return $h->add($k, $v) } } }, 'set', ['k'], [5], 5, 'sketch coderef set');
check_adapter('Data::Shared::Adapter::Indexed', { key => 'mock', verbs => { set => 'update', incr => 'update' } }, 'set', ['1', '2'], [5], 5, 'indexed set');
check_adapter('Data::Shared::Adapter::Queue', { key => 'mock', verbs => { get => 'get' } }, 'get', ['k'], [], 10, 'queue verb get');

for my $a (qw(Map Set Indexed Queue Sketch Sync)) {
    my $adapter = "Data::Shared::Adapter::$a";
    my $entry = { key => 'mock', verbs => {} };
    ok !$adapter->make_verb('get', MockHandle->new, $entry), "$a unknown verb undef";
    ok !eval { $adapter->perform('get', MockHandle->new, $entry, ['k']); 1 }, "$a perform unknown croaks";
    ok !$adapter->make_bound('get', MockHandle->new, $entry, ['k']), "$a unknown bound undef";
}

{
    my $entry = { key => 'mock', verbs => { get => 'nosuch_method' } };
    my $code = Data::Shared::Adapter::Map->make_verb('get', MockHandle->new, $entry);
    ok $code, 'missing method still returns code';
    ok !eval { $code->(['k']); 1 }, 'missing method code croaks on call';
    like $@, qr/does not support/, 'missing method error';
    my $bound = Data::Shared::Adapter::Map->make_bound('get', MockHandle->new, $entry, ['k']);
    ok !eval { $bound->(); 1 }, 'missing method bound croaks';
    ok !eval { Data::Shared::Adapter::Map->perform('get', MockHandle->new, $map_entry, []); 1 }, 'too short croaks';
    like $@, qr/no key/, 'too short error';
    ok !eval { Data::Shared::Adapter::Indexed->perform('get', MockHandle->new, { key => 'mock', verbs => { get => 'point' } }, []); 1 }, 'indexed too short croaks';
}

{
    my $h = MockHandle->new;
    my $entry = { key => 'mock', verbs => {}, push => 'push', pop => 'pop' };
    my $push = Data::Shared::Adapter::Queue->make_push($h, $entry);
    my $pop = Data::Shared::Adapter::Queue->make_pop($h, $entry);
    $push->([], 42);
    is $pop->([]), 42, 'queue push/pop codes';
    my $bp = Data::Shared::Adapter::Queue->make_bound_push($h, $entry, []);
    my $bo = Data::Shared::Adapter::Queue->make_bound_pop($h, $entry, []);
    $bp->(43);
    is $bo->(), 43, 'queue bound push/pop';
    is(Data::Shared::Adapter::Queue->perform_push($h, $entry, [], 44), 1, 'queue perform_push');
    is(Data::Shared::Adapter::Queue->perform_pop($h, $entry, []), 44, 'queue perform_pop');
    my $no_push = { key => 'mock', verbs => {} };
    ok !$no_push->{push} && !Data::Shared::Adapter::Queue->make_push($h, $no_push), 'queue no push undef';
    ok !eval { Data::Shared::Adapter::Queue->perform_push($h, $no_push, [], 1); 1 }, 'queue perform_push croaks';
    ok !eval { Data::Shared::Adapter::Map->perform_push($h, $map_entry, [], 1); 1 }, 'map perform_push croaks';
    ok !eval { Data::Shared::Adapter::Sync->perform_pop($h, $map_entry, []); 1 }, 'sync perform_pop croaks';
    is(Data::Shared::Adapter::Sync->make_push($h, $map_entry), undef, 'sync make_push undef');
    my $pair = Data::Shared::Adapter::Queue->make_bound_pop($h, { key => 'mock', pop => 'pair' }, []);
    is_deeply [$pair->()], [7, 42], 'bound pop preserves list context';
    is scalar($pair->()), 42, 'bound pop preserves scalar context';
}

done_testing;
