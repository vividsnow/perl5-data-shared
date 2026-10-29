package Data::Shared::Registry;
use strict;
use warnings;
use Carp ();

our $VERSION = '0.01';

our @CARP_NOT = qw(Data::Shared Data::Shared::Adapter::Map
                   Data::Shared::Adapter::Set Data::Shared::Adapter::Indexed
                   Data::Shared::Adapter::Sketch);

# One shape test for every integer-addressed entry, used by the exists verbs
# here and by the adapters' key handling for the rest. Keeping two copies is
# what let a trailing newline pass one and not the other. [0-9], not \d: \d
# also matches non-ASCII digits, which numify to the element they look like,
# so U+0661 walked past an earlier guard and overwrote element 0.
# One compiled pattern, used directly by both, so neither pays a call for the
# other and there is still only one definition to keep right.
my $INDEX_SHAPE = qr/\A-?[0-9]+\z/;

sub _index_shape_ok {
    return defined $_[0] && $_[0] =~ $INDEX_SHAPE ? 1 : 0;
}

# Entries flagged key_int get this from the adapter, for every verb but
# exists, which is documented to answer 1 or 0 for any path.
sub _assert_index {
    my ($key, $idx) = @_;
    Carp::croak("$key: index must be an integer, not '" . (defined $idx ? $idx : 'undef') . "'")
        unless defined $idx && $idx =~ $INDEX_SHAPE;
    return $idx;
}

sub _capacity_exists {
    return sub {
        my ($h, $idx) = @_;
        return 0 unless _index_shape_ok($idx);
        return 0 if $idx < 0;
        return $idx < $h->capacity ? 1 : 0;
    };
}

# The same bounds check in front of a backend whose own test croaks out of
# range: exists is documented to answer 1 or 0 for any path, and a caller
# probing candidate indices died instead of being told no.
sub _bounded_exists {
    my ($method) = @_;
    return sub {
        my ($h, $idx) = @_;
        return 0 unless _index_shape_ok($idx);
        return 0 if $idx < 0 || $idx >= $h->capacity;
        return $h->$method($idx) ? 1 : 0;
    };
}

our %REGISTRY = (
    bitset => {
        key => 'bitset', dist => 'Data-BitSet-Shared',
        class => 'Data::BitSet::Shared', path_class => 'set',
        verbs => {
            get    => 'test',
            exists => _bounded_exists('test'),
            # No value read as false and cleared the bit, reporting success.
            # @_ < 3, not an undef test: an explicit undef still means the
            # caller meant to pass something, as Node::delete reads it.
            set    => sub { my ($h, $idx, $v) = @_;
                Carp::croak("bitset set needs a value (1 to set, 0 to clear)") if @_ < 3;
                return $v ? $h->set($idx) : $h->clear($idx) },
            delete => 'clear',
        },
    },
    bloomfilter => {
        key => 'bloomfilter', dist => 'Data-BloomFilter-Shared',
        class => 'Data::BloomFilter::Shared', path_class => 'set',
        verbs => {
            get => 'contains', exists => 'contains',
            set => sub { my ($h, $k, $v) = @_; return $h->add($k) },
        },
    },
    buffer => {
        key => 'buffer', dist => 'Data-Buffer-Shared',
        class => 'Data::Buffer::Shared::I64', path_class => 'map',
        key_int => 1,
        variants => { map { $_ => { class => "Data::Buffer::Shared::$_", load => "Data::Buffer::Shared::$_" } }
                      qw(I8 I16 I32 I64 U8 U16 U32 U64 F32 F64 Str) },
        verbs => {
            get => 'get', set => 'set',
            exists => _capacity_exists(),
            delete => sub { my ($h, $idx) = @_; return $h->set($idx, 0) },
            incr => 'incr',
        },
    },
    countingbloomfilter => {
        key => 'countingbloomfilter', dist => 'Data-CountingBloomFilter-Shared',
        class => 'Data::CountingBloomFilter::Shared', path_class => 'set',
        verbs => {
            get => 'count_of', exists => 'contains',
            set => sub { my ($h, $k, $v) = @_; return $h->add($k) },
            delete => 'remove',
        },
    },
    countminsketch => {
        key => 'countminsketch', dist => 'Data-CountMinSketch-Shared',
        class => 'Data::CountMinSketch::Shared', path_class => 'sketch',
        verbs => {
            get => 'estimate',
            exists => sub { my ($h, $k) = @_; return $h->estimate($k) > 0 ? 1 : 0 },
            set => sub { my ($h, $k, $v) = @_; return $h->add($k, defined $v ? $v : 1) },
        },
    },
    cuckoofilter => {
        key => 'cuckoofilter', dist => 'Data-CuckooFilter-Shared',
        class => 'Data::CuckooFilter::Shared', path_class => 'set',
        verbs => {
            get => 'count_of', exists => 'contains',
            set => sub { my ($h, $k, $v) = @_; return $h->add($k) },
            delete => 'remove',
        },
    },
    ddsketch => {
        key => 'ddsketch', dist => 'Data-DDSketch-Shared',
        class => 'Data::DDSketch::Shared', path_class => 'sketch',
        verbs => {},
    },
    deque => {
        key => 'deque', dist => 'Data-Deque-Shared',
        class => 'Data::Deque::Shared::Int', load => 'Data::Deque::Shared',
        path_class => 'queue',
        variants => {
            Int => { class => 'Data::Deque::Shared::Int', load => 'Data::Deque::Shared' },
            Str => { class => 'Data::Deque::Shared::Str', load => 'Data::Deque::Shared' },
        },
        verbs => {}, push => 'push_back', pop => 'pop_front',
    },
    disjointset => {
        key => 'disjointset', dist => 'Data-DisjointSet-Shared',
        class => 'Data::DisjointSet::Shared', path_class => 'set',
        key_int => 1,
        verbs => {
            get => 'find',
            exists => _capacity_exists(),
            # Without the guard a missing second member numified to 0 and
            # unioned the member with element 0. DisjointSet has no split, so
            # that merge is permanent.
            set => sub {
                my ($h, $m, $other) = @_;
                Carp::croak("disjointset set needs a second member to union with")
                    unless _index_shape_ok($other);
                return $h->union($m, $other);
            },
        },
    },
    fenwick => {
        key => 'fenwick', dist => 'Data-Fenwick-Shared',
        class => 'Data::Fenwick::Shared', path_class => 'indexed',
        key_int => 1,
        verbs => {
            get => 'point', set => 'set', incr => 'update',
            exists => sub { my ($h, $p) = @_;
                return (_index_shape_ok($p) && $p >= 1 && $p <= $h->size) ? 1 : 0 },
            delete => sub { my ($h, $p) = @_; return $h->set($p, 0) },
        },
    },
    fenwick2d => {
        key => 'fenwick2d', dist => 'Data-Fenwick2D-Shared',
        class => 'Data::Fenwick2D::Shared', path_class => 'indexed',
        key_int => 1,
        verbs => { get => 'point', set => 'set', incr => 'update' },
    },
    graph => {
        key => 'graph', dist => 'Data-Graph-Shared',
        class => 'Data::Graph::Shared', path_class => 'indexed',
        key_int => 1,
        # has_node is an honest exists, and get croaks on a node that is not
        # there, so without it a caller had no probe that answers rather than
        # dying.
        verbs => { get => 'node_data', delete => 'remove_node', exists => 'has_node' },
    },
    hashmap => {
        key => 'hashmap', dist => 'Data-HashMap-Shared',
        class => 'Data::HashMap::Shared::II', path_class => 'map',
        variants => { map { $_ => { class => "Data::HashMap::Shared::$_", load => "Data::HashMap::Shared::$_" } }
                      qw(I16 I16S I32 I32S II IS SI SI16 SI32 SS) },
        verbs => {
            get => 'get', set => 'put', delete => 'remove',
            exists => 'exists', incr => 'incr',
        },
    },
    heap => {
        key => 'heap', dist => 'Data-Heap-Shared',
        class => 'Data::Heap::Shared', path_class => 'queue',
        verbs => {}, push => 'push', pop => 'pop',
    },
    hiertimingwheel => {
        key => 'hiertimingwheel', dist => 'Data-HierTimingWheel-Shared',
        class => 'Data::HierTimingWheel::Shared', path_class => 'sync',
        verbs => {},
    },
    histogram => {
        key => 'histogram', dist => 'Data-Histogram-Shared',
        class => 'Data::Histogram::Shared', path_class => 'sketch',
        verbs => {},
    },
    hyperloglog => {
        key => 'hyperloglog', dist => 'Data-HyperLogLog-Shared',
        class => 'Data::HyperLogLog::Shared', path_class => 'sketch',
        verbs => {},
    },
    intern => {
        key => 'intern', dist => 'Data-Intern-Shared',
        class => 'Data::Intern::Shared', path_class => 'map',
        verbs => {
            get => 'id_of',
            set => sub { my ($h, $k, $v) = @_; return $h->intern($k) },
            exists => 'exists',
        },
    },
    intervaltree => {
        key => 'intervaltree', dist => 'Data-IntervalTree-Shared',
        class => 'Data::IntervalTree::Shared', path_class => 'indexed',
        verbs => {},
    },
    kdtree => {
        key => 'kdtree', dist => 'Data-KDTree-Shared',
        class => 'Data::KDTree::Shared', path_class => 'indexed',
        verbs => {},
    },
    log => {
        key => 'log', dist => 'Data-Log-Shared',
        class => 'Data::Log::Shared', path_class => 'queue',
        verbs => {}, push => 'append',
    },
    minhash => {
        key => 'minhash', dist => 'Data-MinHash-Shared',
        class => 'Data::MinHash::Shared', path_class => 'sketch',
        verbs => {},
    },
    ndarray => {
        key => 'ndarray', dist => 'Data-NDArray-Shared',
        class => 'Data::NDArray::Shared', path_class => 'indexed',
        key_int => 1,
        verbs => { get => 'get', set => 'set' },
    },
    perfecthash => {
        key => 'perfecthash', dist => 'Data-PerfectHash-Shared',
        class => 'Data::PerfectHash::Shared', path_class => 'map',
        ctor => 'handle_only', immutable => 1,
        verbs => { get => 'has', exists => 'has' },
    },
    pool => {
        key => 'pool', dist => 'Data-Pool-Shared',
        class => 'Data::Pool::Shared', load => 'Data::Pool::Shared',
        path_class => 'map',
        variants => {
            I64 => { class => 'Data::Pool::Shared::I64', load => 'Data::Pool::Shared' },
            I32 => { class => 'Data::Pool::Shared::I32', load => 'Data::Pool::Shared' },
            F64 => { class => 'Data::Pool::Shared::F64', load => 'Data::Pool::Shared' },
            Str => { class => 'Data::Pool::Shared::Str', load => 'Data::Pool::Shared' },
        },
        verbs => {
            get => 'get', set => 'set', delete => 'free',
            exists => _bounded_exists('is_allocated'),
            # add() takes a mandatory delta and incr() takes none, so mapping
            # the verb to either one alone left the other form croaking from
            # the XS: the no-delta form, which the POD calls the base form,
            # could never succeed on a variant that has both.
            incr => sub { my ($h, $slot, @delta) = @_;
                return $h->add($slot, $delta[0]) if @delta && $h->can('add');
                return $h->incr($slot) if !@delta && $h->can('incr');
                Carp::croak('pool: ' . ref($h) . " does not support 'incr'"
                    . (@delta ? ' with a delta' : ' without a delta')
                    . ' (use shared_call for operations outside the generic verbs)') },
        },
    },
    pubsub => {
        key => 'pubsub', dist => 'Data-PubSub-Shared',
        class => 'Data::PubSub::Shared::Int', path_class => 'queue',
        variants => { map { $_ => { class => "Data::PubSub::Shared::$_", load => "Data::PubSub::Shared::$_" } }
                      qw(Int Int32 Int16 Str) },
        verbs => {}, push => 'publish',
    },
    queue => {
        key => 'queue', dist => 'Data-Queue-Shared',
        class => 'Data::Queue::Shared::Int', path_class => 'queue',
        variants => { map { $_ => { class => "Data::Queue::Shared::$_", load => "Data::Queue::Shared::$_" } }
                      qw(Int Int32 Int16 Str) },
        verbs => {}, push => 'push', pop => 'pop',
    },
    radixtree => {
        key => 'radixtree', dist => 'Data-RadixTree-Shared',
        class => 'Data::RadixTree::Shared', path_class => 'map',
        key_join => '/',
        verbs => {
            get => 'lookup',
            set => sub { my ($h, $k, $v) = @_;
                Carp::croak("radixtree set needs a value") if @_ < 3;
                return $h->insert($k, $v) },
            delete => 'delete', exists => 'exists',
        },
    },
    reqrep => {
        key => 'reqrep', dist => 'Data-ReqRep-Shared',
        class => 'Data::ReqRep::Shared', path_class => 'sync',
        variants => {
            Int => { class => 'Data::ReqRep::Shared::Int', load => 'Data::ReqRep::Shared::Int' },
        },
        verbs => {},
    },
    reservoir => {
        key => 'reservoir', dist => 'Data-Reservoir-Shared',
        class => 'Data::Reservoir::Shared', path_class => 'sketch',
        variants => {
            weighted => { class => 'Data::Reservoir::Shared', load => 'Data::Reservoir::Shared', ctor => 'new_weighted' },
        },
        verbs => {},
    },
    ringbuffer => {
        key => 'ringbuffer', dist => 'Data-RingBuffer-Shared',
        class => 'Data::RingBuffer::Shared::Int', load => 'Data::RingBuffer::Shared',
        path_class => 'queue',
        variants => {
            Int => { class => 'Data::RingBuffer::Shared::Int', load => 'Data::RingBuffer::Shared' },
            F64 => { class => 'Data::RingBuffer::Shared::F64', load => 'Data::RingBuffer::Shared' },
        },
        verbs => {
            get => sub { my ($h, @rest) = @_; return @rest ? $h->read_seq($rest[0]) : $h->latest },
        },
        push => 'write',
    },
    roaringbitmap => {
        key => 'roaringbitmap', dist => 'Data-RoaringBitmap-Shared',
        class => 'Data::RoaringBitmap::Shared', path_class => 'set',
        verbs => {
            get => 'contains', exists => 'contains',
            set => sub { my ($h, $m, $v) = @_; return $h->add($m) },
            delete => 'remove',
        },
    },
    segmenttree => {
        key => 'segmenttree', dist => 'Data-SegmentTree-Shared',
        class => 'Data::SegmentTree::Shared', path_class => 'indexed',
        key_int => 1,
        verbs => {
            # One index, as every other verb of a 1-D leaf takes: dropping the
            # extra components answered a point query for a path that named
            # something else, where the string-mapped verbs croak.
            get => sub { my ($h, @p) = @_;
                Carp::croak('segmenttree: get takes one index; use shared_call for a range')
                    if @p != 1;
                return $h->sum($p[0], $p[0]) },
            set => 'set', incr => 'add',
            # Without the shape check a non-numeric index numified to 0, which
            # is in range, so exists answered true for any member.
            exists => sub { my ($h, $p) = @_;
                return (_index_shape_ok($p) && $p >= 0 && $p < $h->size) ? 1 : 0 },
            delete => sub { my ($h, $p) = @_; return $h->set($p, 0) },
        },
    },
    sortedset => {
        key => 'sortedset', dist => 'Data-SortedSet-Shared',
        class => 'Data::SortedSet::Shared', path_class => 'set',
        variants => {
            Strings => { class => 'Data::SortedSet::Shared::Strings', load => 'Data::SortedSet::Shared::Strings' },
        },
        verbs => {
            get => 'score', exists => 'exists',
            set => sub { my ($h, $m, $score) = @_;
                Carp::croak("sortedset set needs a score") if @_ < 3;
                return $h->add($m, $score) },
            delete => 'remove',
            # A delta is required, not defaulted. Without one the integer class
            # croaks from its XS but the Strings wrapper interned the member,
            # added nothing, and returned the unchanged score as if it had
            # worked -- and on a member that did not exist it left a ghost
            # behind with score 0.
            incr => sub { my ($h, $m, @delta) = @_;
                Carp::croak('sortedset incr needs a delta') unless @delta;
                return $h->incr($m, $delta[0]) },
        },
    },
    spatialhash => {
        key => 'spatialhash', dist => 'Data-SpatialHash-Shared',
        class => 'Data::SpatialHash::Shared', path_class => 'indexed',
        verbs => {},
    },
    stack => {
        key => 'stack', dist => 'Data-Stack-Shared',
        class => 'Data::Stack::Shared::Int', load => 'Data::Stack::Shared',
        path_class => 'queue',
        variants => {
            Int => { class => 'Data::Stack::Shared::Int', load => 'Data::Stack::Shared' },
            Str => { class => 'Data::Stack::Shared::Str', load => 'Data::Stack::Shared' },
        },
        verbs => {}, push => 'push', pop => 'pop',
    },
    sync => {
        key => 'sync', dist => 'Data-Sync-Shared',
        class => 'Data::Sync::Shared::Semaphore', path_class => 'sync',
        variants => { map { $_ => { class => "Data::Sync::Shared::$_", load => "Data::Sync::Shared::$_" } }
                      qw(Semaphore Barrier RWLock Condvar Once) },
        verbs => {},
    },
    timingwheel => {
        key => 'timingwheel', dist => 'Data-TimingWheel-Shared',
        class => 'Data::TimingWheel::Shared', path_class => 'sync',
        verbs => {},
    },
    topk => {
        key => 'topk', dist => 'Data-TopK-Shared',
        class => 'Data::TopK::Shared', path_class => 'sketch',
        variants => {
            decayed => { class => 'Data::TopK::Shared', load => 'Data::TopK::Shared', ctor => 'new_decayed' },
        },
        verbs => {
            get => 'estimate',
            exists => sub { my ($h, $k) = @_; return $h->estimate($k) > 0 ? 1 : 0 },
            set => sub { my ($h, $k, $v) = @_; return $h->add($k) },
        },
    },
);

my %MIN_VERSION = (
    bitset => '0.08', bloomfilter => '0.07', buffer => '0.09',
    countingbloomfilter => '0.05', countminsketch => '0.06', cuckoofilter => '0.06',
    ddsketch => '0.05', deque => '0.11', disjointset => '0.06',
    fenwick => '0.06', fenwick2d => '0.05', graph => '0.08', hashmap => '0.23',
    heap => '0.10', hiertimingwheel => '0.05', histogram => '0.06',
    hyperloglog => '0.06', intern => '0.06', intervaltree => '0.05',
    kdtree => '0.05', log => '0.08', minhash => '0.06', ndarray => '0.06',
    perfecthash => '0.05', pool => '0.10', pubsub => '0.11', queue => '0.10',
    radixtree => '0.06', reqrep => '0.09', reservoir => '0.06', ringbuffer => '0.07',
    roaringbitmap => '0.06', segmenttree => '0.07', sortedset => '0.07',
    spatialhash => '0.06', stack => '0.09', sync => '0.10', timingwheel => '0.05', topk => '0.07',
);
my %NATIVE_READONLY = map { $_ => 1 } qw(bitset bloomfilter countingbloomfilter countminsketch
    cuckoofilter ddsketch fenwick fenwick2d graph hashmap histogram hyperloglog intern
    intervaltree kdtree minhash ndarray radixtree roaringbitmap sortedset spatialhash);
for my $key (keys %REGISTRY) {
    $REGISTRY{$key}{min_version} = $MIN_VERSION{$key};
    $REGISTRY{$key}{freeze} = $NATIVE_READONLY{$key} ? 1 : 0;
    $REGISTRY{$key}{readonly} = $NATIVE_READONLY{$key} ? 'native'
        : $REGISTRY{$key}{immutable} ? 'immutable' : 'unsupported';
}
$REGISTRY{sortedset}{variants}{Strings}{readonly} = 'unsupported';
# The class has neither freeze nor new_readonly, and the %NATIVE_READONLY loop
# above is per-entry, so the inherited freeze => 1 was a wrong published fact.
$REGISTRY{sortedset}{variants}{Strings}{freeze} = 0;

sub registry { return \%REGISTRY }
sub keys_list { my @k = sort keys %REGISTRY; return @k }
sub entry_for_key {
    my ($key) = @_;
    return $REGISTRY{ lc $key };
}

sub entry_for_class {
    my ($class) = @_;
    for my $e (values %REGISTRY) {
        return $e if $e->{class} eq $class;
        if (my $vs = $e->{variants}) {
            for my $v (values %$vs) {
                return $e if $v->{class} eq $class;
            }
        }
    }
    return undef;
}

sub resolve_spec {
    my ($spec) = @_;
    return undef unless defined $spec && !ref $spec;
    if (my $e = $REGISTRY{ lc $spec }) {
        return { entry => $e, class => $e->{class}, load => ($e->{load} // $e->{class}),
                 ctor => ($e->{ctor} // 'new'), variant => undef };
    }
    if ($spec =~ /^([^:]+):(.+)$/) {
        my ($k, $vname) = ($1, $2);
        if (my $e = $REGISTRY{ lc $k }) {
            if (my $vs = $e->{variants}) {
                for my $vn (keys %$vs) {
                    if (lc $vn eq lc $vname) {
                        my $v = $vs->{$vn};
                        return { entry => $e, class => $v->{class},
                                 load => ($v->{load} // $e->{load} // $v->{class}),
                                 ctor => ($v->{ctor} // $e->{ctor} // 'new'),
                                 variant => lc $vn };
                    }
                }
            }
            if (lc $vname eq 'default') {
                return { entry => $e, class => $e->{class}, load => ($e->{load} // $e->{class}),
                         ctor => ($e->{ctor} // 'new'), variant => undef };
            }
        }
    }
    if (my $e = entry_for_class($spec)) {
        my $ctor = $e->{ctor} // 'new';
        my $load = $e->{load} // $spec;
        my $vname;
        if (my $vs = $e->{variants}) {
            for my $vn (sort keys %$vs) {
                if ($vs->{$vn}{class} eq $spec) {
                    next if $e->{class} eq $spec && defined $vs->{$vn}{ctor}
                        && $vs->{$vn}{ctor} ne $ctor;
                    $vname = $vn;
                    $ctor = $vs->{$vn}{ctor} // $ctor;
                    $load = $vs->{$vn}{load} // $load;
                    last;
                }
            }
        }
        return { entry => $e, class => $spec, load => $load, ctor => $ctor, variant => defined $vname ? lc $vname : undef };
    }
    if ($spec =~ /^Data::/) {
        return { entry => undef, class => $spec, load => $spec, ctor => 'new', variant => undef };
    }
    return undef;
}

1;

__END__

=encoding utf8

=head1 NAME

Data::Shared::Registry - Inventory of the 39 Data-*-Shared dists for Data::Shared

=head1 SYNOPSIS

    use Data::Shared::Registry ();
    my $reg = Data::Shared::Registry::registry;
    my $e = $reg->{hashmap};
    # { key, dist, class, variants, path_class, verbs, push, pop, ... }

    my @keys = Data::Shared::Registry::keys_list;   # 39 short names
    my $r = Data::Shared::Registry::resolve_spec('buffer:i64');
    # { entry, class => 'Data::Buffer::Shared::I64', load, ctor, variant }

=head1 DESCRIPTION

This module is the single source of truth that drives
L<Data::Shared>: mount-spec resolution, adapter selection, and
generic verb translation all read it.

Each entry has: C<key> (short mount spec name), C<dist>, C<class>
(default class), optional C<load> (module to require when variant
classes live inside a base F<.pm>), optional C<variants> (name to
C<{class, load, ctor}>), C<path_class> (C<map>, C<set>, C<queue>,
C<indexed>, C<sketch> or C<sync>), C<verbs> (generic verb to native
method name or coderef receiving C<($handle, $key, @args)>, or
C<($handle, @indices, @args)> for indexed leaves), optional
C<push>/C<pop> native method names, optional C<key_join> (join
remaining components with C</> to form the key), optional C<ctor>
(C<new> by default; C<handle_only> for PerfectHash), and C<freeze>
(whether the leaf supports freeze/new_readonly).

C<min_version> records the validated backend version used as the supported
minimum by the installer and runtime loader. C<readonly> describes the
default class as C<native>, C<immutable>, or C<unsupported>; variants may
override this description. Strict read-only opens also inspect the resolved
class for its native constructor. C<immutable> marks build-then-load backends.

A verb absent from C<verbs> means "not honestly expressible
generically"; the facade croaks and points at C<shared_call>. A verb
mapped to a coderef (e.g. BitSet C<set> choosing set-vs-clear by
value, SortedSet C<set> as C<add(member, score)>, Intern C<set> as
C<intern>) wraps the one place where sugar needs a decision.

=head1 FUNCTIONS

=head2 registry

Returns the hashref of all entries keyed by short name.

=head2 keys_list

Sorted list of the 39 short names.

=head2 entry_for_key($key), entry_for_class($class)

Lookups by short name or by Perl class (including variants).

=head2 resolve_spec($spec)

Resolves C<'hashmap'>, C<'hashmap:ii'>, a full class name, or any
C<Data::*> class (unknown classes get a generic call-only entry)
to C<{entry, class, load, ctor, variant}>, or undef for unknown
short specs. Short specs are all-lowercase; the returned C<variant>
is always lowercase.

=cut
