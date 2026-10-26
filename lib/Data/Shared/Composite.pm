package Data::Shared::Composite;
use strict;
use warnings;
use Carp ();
use Scalar::Util qw(weaken);
use Fcntl qw(:flock);
use Errno ();

our $VERSION = '0.01';

our @CARP_NOT = qw(Data::Shared Data::Shared::Manifest Data::Shared::Storage
                   Data::Shared::Composite);

sub CLONE_SKIP { 1 }

my %PARENT_OK = map { $_ => 1 } qw(hashmap sortedset kdtree graph);

sub _is_opts_hash {
    my ($h) = @_;
    return 0 unless ref $h eq 'HASH' && %$h;
    for my $k (keys %$h) { return 0 unless $k eq 'max_children' || $k eq 'cache_size' }
    return 1;
}

sub parse_node {
    my ($node) = @_;
    if (!ref $node) {
        Carp::croak("composite spec must be a string, arrayref, or hashref") unless defined $node;
        my $resolved = Data::Shared::Registry::resolve_spec($node);
        Carp::croak("Data::Shared: unknown mount spec '$node'") unless $resolved;
        return { spec => $node, resolved => $resolved, args => [], child => undef,
                 max_children => 10_000, cache_size => 32 };
    }
    if (ref $node eq 'HASH') {
        my $spec = $node->{spec} // $node->{type} // $node->{class} // $node->{key};
        Carp::croak("composite hashref spec needs spec/type/class/key") unless defined $spec;
        my $resolved = Data::Shared::Registry::resolve_spec($spec);
        Carp::croak("Data::Shared: unknown mount spec '$spec'") unless $resolved;
        Carp::croak('Data::Shared: constructor args must be an ARRAY reference')
            if exists $node->{args} && ref $node->{args} ne 'ARRAY';
        Carp::croak('Data::Shared: invalid constructor name')
            if exists $node->{ctor} && (!defined $node->{ctor} || ref $node->{ctor} || $node->{ctor} !~ /\A[A-Za-z_]\w*\z/);
        $resolved = { %$resolved, ctor => $node->{ctor} } if defined $node->{ctor};
        my $out = { spec => $spec, resolved => $resolved,
                    args => $node->{args} ? [ @{ $node->{args} } ] : [],
                    child => undef,
                    max_children => $node->{max_children} // 10_000,
                    cache_size => $node->{cache_size} // 32 };
        $out->{child} = parse_node($node->{child}) if defined $node->{child};
        _validate_node($out);
        return $out;
    }
    if (ref $node eq 'ARRAY') {
        my @elems = @$node;
        Carp::croak("composite arrayref spec is empty") unless @elems;
        my $spec = shift @elems;
        Carp::croak("composite arrayref spec must start with a spec string") if ref $spec;
        my %opts;
        if (@elems >= 2 && ref $elems[-1] eq 'HASH' && ref $elems[-2] eq 'ARRAY') {
            # This is unambiguously the documented child+options shape, so a key
            # that is not an option is a typo. Without this the hash fell through
            # to the parent's constructor arguments and the mount became a plain
            # leaf with no warning, failing later on the first deep write.
            unless (_is_opts_hash($elems[-1])) {
                my @bad = sort grep { $_ ne 'max_children' && $_ ne 'cache_size' }
                    keys %{ $elems[-1] };
                Carp::croak("Data::Shared: unknown composite option"
                    . (@bad == 1 ? " '$bad[0]'" : "s '" . join("', '", @bad) . "'")
                    . "; expected max_children or cache_size");
            }
            %opts = %{ pop @elems };
        }
        my $child;
        if (@elems && ref $elems[-1] eq 'ARRAY') {
            $child = parse_node(pop @elems);
        }
        my $resolved = Data::Shared::Registry::resolve_spec($spec);
        Carp::croak("Data::Shared: unknown mount spec '$spec'") unless $resolved;
        my $out = { spec => $spec, resolved => $resolved, args => \@elems, child => $child,
                    max_children => $opts{max_children} // 10_000,
                    cache_size => $opts{cache_size} // 32 };
        _validate_node($out);
        return $out;
    }
    Carp::croak("composite spec must be a string, arrayref, or hashref");
}

sub _constructor_args {
    my ($resolved, $args) = @_;
    my @a = @$args;
    shift @a if @a && (!defined $a[0] || (!ref $a[0] && $a[0] eq ':file'));
    return \@a if $resolved->{class} eq 'Data::SortedSet::Shared::Strings'
        || ($resolved->{entry} && ($resolved->{entry}{ctor} // '') eq 'handle_only');
    return [undef, @a];
}

sub construct_node {
    my ($dir, $readonly, $resolved, $name, $args, $mode) = @_;
    return Data::Shared::_construct_with($dir, $readonly, $resolved, $name,
        _constructor_args($resolved, $args), $mode || {});
}

sub _preflight {
    my ($root, $node, $dir, $opening) = @_;
    if ($root->{strict_readonly}) {
        my $current = $node;
        while ($current) {
            Data::Shared::Storage::check_readonly($current->{resolved});
            $current = $current->{child};
        }
    }
    return unless $opening;
    Carp::croak("Data::Shared: missing composite directory '" . ($dir // '') . "'") unless defined $dir && -d $dir;
    my $context = bless { dir => $dir }, 'Data::Shared';
    my $parent = Data::Shared::Storage::plan($context, $node->{resolved}, 'parent',
        _constructor_args($node->{resolved}, $node->{args}));
    my $index = Data::Shared::Storage::plan($context,
        _index_spec(), 'index', _index_args($node));
    Data::Shared::Storage::require_files($_) for ($parent, $index);
}

sub _validate_node {
    my ($node) = @_;
    return unless $node->{child};
    my $entry = $node->{resolved}{entry};
    my $key = $entry ? $entry->{key} : undef;
    Carp::croak("Data::Shared: '" . (defined $key ? $key : $node->{spec})
        . "' cannot be a composite parent (only hashmap, sortedset, kdtree, and graph can); use it as a leaf or a sidecar")
        unless defined $key && $PARENT_OK{$key};
    for my $option (qw(max_children cache_size)) {
        Carp::croak("Data::Shared: composite $option must be an integer >= 1")
            unless defined $node->{$option} && !ref $node->{$option}
                && $node->{$option} =~ /\A[1-9]\d*\z/;
    }
}

sub new {
    my ($class, %o) = @_;
    my $node = $o{node} or Carp::croak('Composite requires a node');
    my $self = bless { node => $node, dir => $o{dir}, path => [ @{ $o{path} || [] } ],
        name => $o{name}, readonly => $o{readonly} ? 1 : 0,
        _cleanup => $o{cleanup} ? 1 : 0, _frozen_ok => $o{frozen_ok} ? 1 : 0,
        strict_readonly => $o{strict_readonly} ? 1 : 0,
        cache => {}, lru_prev => {}, lru_next => {}, gen => 0 }, $class;
    $self->{root_weak} = $o{root};
    weaken($self->{root_weak}) if $self->{root_weak};
    _preflight($self, $node, $self->{dir}, $o{opening});
    if (defined $self->{dir} && !$o{opening}) {
        require File::Path;
        File::Path::make_path($self->{dir});
    }
    $self->_with_lock(sub {
        my %mode = (opening => $o{opening}, strict_readonly => $self->{strict_readonly},
            pending_paths => $o{pending_paths}, cleanup => $self->{_cleanup},
            frozen_ok => $self->{_frozen_ok});
        my ($parent) = construct_node($self->{dir}, $self->{readonly}, $node->{resolved}, 'parent', $node->{args}, \%mode);
        $self->{parent_handle} = $parent;
        $self->{parent_record} = { handle => $parent, entry => $node->{resolved}{entry}, dt => {} };
        my ($index) = Data::Shared::_construct_with($self->{dir}, $self->{readonly},
            _index_spec(), 'index', _index_args($node), \%mode);
        $self->{index} = $index;
        Carp::croak('Data::Shared: composite instance was deleted') if $index->get('x:') && !$self->{_cleanup};
        # Only after an interrupted mutation: 's:' is maintained inside every
        # mutating lock section and 'p:' marks one that did not finish, so an
        # unmarked counter is already correct. Recounting unconditionally made
        # a cold open O(children) -- and every cache miss on a nested composite
        # is a cold open -- while writing to the index on a pure read path.
        # _index_frozen, not frozen: the question here is whether the index can
        # take the write, not whether the subtree is shippable. A composite
        # with an unshippable level answers false to the latter, so the guard
        # did not fire and the write hit the sealed index.
        if (!$self->{readonly} && !$self->{_cleanup} && !$self->_index_frozen
            && ($index->get('p:') || !defined $index->get('s:'))) {
            $self->_index_put('s:', $self->_count_addresses);
            $self->_index_remove('p:');
        }
    });
    return $self;
}

sub _root {
    my ($self, $root) = @_;
    return $root if $root;
    my $r = $self->{root_weak};
    Carp::croak("Data::Shared: root has gone away") unless $r;
    return $r;
}

# Both are pure functions of the resolved spec, which is fixed for the life of
# the instance, and both sit on the address path of every child operation.
sub _key_is_int {
    my ($self) = @_;
    return $self->{_key_is_int} //= _key_is_int_for($self);
}

sub _key_int_bits {
    my ($self) = @_;
    return $self->{_key_int_bits} //= _key_int_bits_for($self);
}

sub _key_is_int_for {
    my ($self) = @_;
    my $node = $self->{node};
    # kdtree and graph address a child per point/node id, so their keys are
    # integers even though the parent class carries no int variant.
    return 1 if $self->_is_index_parent;
    return 0 if $node->{resolved}{class} eq 'Data::SortedSet::Shared::Strings';
    return 1 if $node->{resolved}{entry} && ($node->{resolved}{entry}{key} || '') eq 'sortedset';
    my $variant = $node->{resolved}{variant};
    if (defined $variant) {
        return ($variant =~ /^(?:i16|i32|ii|is)/) ? 1 : 0;
    }
    my $class = $node->{resolved}{class};
    return 1 if $class =~ /::(?:II|I16|I32|IS|I16S|I32S)$/;
    return 0;
}

sub _valid_address {
    my ($self, $addr) = @_;
    return 0 unless defined $addr;
    # Canonical form, and \z not $: the child index keys on the address string
    # while an int-keyed parent keys on its numeric value, so '007', '-0' and
    # "7\n" each registered a separate child over one parent slot. Deleting one
    # then removed the parent's record while its twin stayed registered.
    return 0 if $self->_key_is_int && $addr !~ /\A(?:0|-?[1-9][0-9]*)\z/;
    # Same collision one step further out: a fixed-width parent truncates the
    # key it stores, so on an i16 parent 70000 and 4464 share one slot while
    # the index keys both strings. Only composite parents are checked; a plain
    # leaf mount keeps the backend's documented wrapping.
    if (my $bits = $self->_key_int_bits) {
        my ($neg, $mag) = $addr =~ /\A(-?)([0-9]+)\z/;
        my $limit = $bits == 64
            ? ($neg ? '9223372036854775808' : '9223372036854775807')
            : (1 << ($bits - 1)) - ($neg ? 0 : 1);
        # Compared as strings: a canonical address has no leading zeros, so at
        # equal length lexical order is numeric order, and the 64-bit limits do
        # not survive a double (-9223372036854775809 rounds to the minimum and
        # would pass a numeric test).
        return 0 if length($mag) > length($limit)
                 || (length($mag) == length($limit) && $mag gt $limit);
    }
    return 1;
}

sub _key_int_bits_for {
    my ($self) = @_;
    # An id-parent keeps no mirror slot, so an id outside the range cannot
    # collide with another address there.
    return 0 if $self->_is_index_parent;
    my $resolved = $self->{node}{resolved};
    my $probe = defined $resolved->{variant} ? $resolved->{variant}
              : ($resolved->{class} =~ /::(\w+)\z/ ? lc $1 : '');
    return 16 if $probe =~ /\Ai16/;
    return 32 if $probe =~ /\Ai32/;
    # Any other int-keyed parent stores the key at IV width, and wraps there
    # just as the narrow ones do: 2**63 and -2**63 shared one mirror slot.
    return $self->_key_is_int ? 64 : 0;
}

sub _with_lock {
    my ($self, $code, $mutating) = @_;
    return $code->() if $self->{readonly} || $self->{_locked};
    my $fh;
    if (defined $self->{dir}) {
        my $lockfile = "$self->{dir}/.lock";
        Carp::croak("Data::Shared: missing composite directory '$self->{dir}'") unless -d $self->{dir};
        CORE::open $fh, '>>', $lockfile or Carp::croak("Data::Shared: cannot open composite lock '$lockfile': $!");
        # Retry on EINTR, as Manifest::with_lock does: this lock is taken on
        # every child create, open-miss and delete, so a signal in a server
        # process made a hot path fail spuriously.
        until (flock $fh, LOCK_EX) {
            Carp::croak("Data::Shared: cannot lock composite: $!") unless $!{EINTR};
        }
    } else {
        unless ($self->{lock_handle}) {
            # RWLock, not Semaphore: a dead Semaphore holder's permit is never
            # restored, so a worker killed inside a lifecycle section wedged
            # every other process sharing an anonymous root, in a futex wait no
            # Perl signal handler can break. RWLock recovers a dead owner's
            # lock. Write-locked throughout; _locked already guards re-entry.
            Data::Shared::_require_class('Data::Sync::Shared::RWLock');
            $self->{lock_handle} = Data::Sync::Shared::RWLock->new(undef);
        }
        $self->{lock_handle}->wrlock;
    }
    local $self->{_locked} = 1;
    my $want = wantarray;
    my (@ret, $ret);
    my $ok = eval {
        if ($self->{index}) {
            Carp::croak('Data::Shared: composite instance was deleted') if $self->{index}->get('x:') && !$self->{_cleanup};
            # A sealed index can never take the write, and a count is derived
            # from the addresses when it is absent, so rebuilding it there
            # could only croak.
            if ($self->{index}->get('p:') && !$self->_index_frozen) {
                $self->_index_put('s:', $self->_count_addresses);
                $self->_index_remove('p:');
            }
            $self->_index_put('p:', 1) if $mutating;
        }
        if ($want) { @ret = $code->() } elsif (defined $want) { $ret = $code->() } else { $code->() }
        $self->_index_remove('p:') if $mutating && $self->{index};
        1;
    };
    my $err = $@;
    if ($fh) { close $fh }
    else { $self->{lock_handle}->wrunlock }
    die $err unless $ok;
    return $want ? @ret : $ret;
}

# Each child stores two registry keys, 'a:<address>' and 'c:<address>', and each
# takes a string-arena block of next_pow2(2 + length $address). The backend's
# default arena is 128 bytes per declared entry, which only covers addresses up
# to 126: beyond that the arena ran out at half (or a quarter) of max_children,
# and raising max_children did not help because the shortfall is a ratio. 272
# per entry covers addresses to 254. The mapping is sparse, so a wider cap costs
# apparent size rather than resident pages, and it is never below the backend's
# own default, so no working budget shrinks. Both call sites must pass the same
# arguments or reopening an existing composite fails, hence the shared helper.
my $INDEX_ARENA_PER_ENTRY = 272;
my $INDEX_ARENA_MAX       = 0xFFFFFFFF;

# 'freeze' is deliberately NOT here: routing it to the composite freezes the
# child index too, which blocks the retirement record a later delete must write.
# Freezing a whole subtree is what $root->freeze_all is for.
my %LIFECYCLE_METHOD = map { $_ => 1 } qw(stats sync unlink destroy frozen);

# Already frozen is the goal state, not an error, so freeze stays idempotent
# even if a leaf was frozen directly first.
sub _freeze_once {
    my ($handle) = @_;
    return 0 unless $handle && $handle->can('freeze');
    return 0 if $handle->can('frozen') && $handle->frozen;
    $handle->freeze;
    return 1;
}

sub _index_spec { return Data::Shared::Registry::resolve_spec('hashmap:ss') }

sub _index_args {
    my ($node) = @_;
    my $entries = 2 * $node->{max_children} + 16;
    my $arena   = $entries * $INDEX_ARENA_PER_ENTRY;
    $arena = $INDEX_ARENA_MAX if $arena > $INDEX_ARENA_MAX;
    return [undef, $entries, 0, 0, 0, $arena];
}

sub _index_put {
    my ($self, $key, $value) = @_;
    return 1 if $self->{index}->put($key, $value);
    my $s = ($self->{index}->can('stats') ? $self->{index}->stats : undef) || {};
    # Name the exhausted resource; the old message pasted the whole address in
    # and said only "cannot write", which reads like an I/O error.
    my $shown = length($key) > 72 ? substr($key, 0, 69) . '...' : $key;
    Carp::croak(sprintf
        "Data::Shared: composite registry is full, cannot write '%s'"
        . " (entries %s/%s, string arena %s/%s bytes, max_children=%s)",
        $shown, map { defined $_ ? $_ : '?' }
            $s->{size}, $s->{max_entries}, $s->{arena_used}, $s->{arena_cap},
            $self->{node}{max_children});
}

sub _index_remove {
    my ($self, $key) = @_;
    $self->{index}->remove($key);
    Carp::croak("Data::Shared: cannot remove composite registry '$key'") if $self->{index}->exists($key);
}

sub _reg_id {
    my ($self, $addr) = @_;
    return $self->{index}->get('a:' . $addr);
}

sub _reg_constructed {
    my ($self, $addr, $id) = @_;
    my $value = $self->{index}->get('c:' . $addr);
    return 0 unless defined $value && length $value;
    return 1 if $value eq '1'; # legacy readiness flag
    $id = $self->_reg_id($addr) unless defined $id;
    return defined $id && $value eq "id:$id" ? 1 : 0;
}

sub _count_addresses {
    my ($self) = @_;
    my @keys = $self->{index}->keys;
    return scalar grep { substr($_, 0, 2) eq 'a:' } @keys;
}

sub _child_count {
    my ($self) = @_;
    if (!$self->{_locked} && $self->{index}->get('p:')) {
        return $self->_count_addresses if $self->{readonly};
        return $self->_with_lock(sub { $self->{index}->get('s:') });
    }
    my $count = $self->{index}->get('s:');
    return defined $count ? $count : $self->_count_addresses;
}

sub _allocate_id {
    my ($self) = @_;
    Carp::croak("Data::Shared: composite child limit exceeded (max_children=$self->{node}{max_children}) at $self->{name}")
        if $self->_child_count >= $self->{node}{max_children};
    my $id = $self->{index}->get('n:') // 0;
    Carp::croak('Data::Shared: invalid composite child sequence') unless $id =~ /\A\d+\z/;
    $self->_index_put('n:', $id + 1); # IDs are never rolled back or reused.
    return $id;
}

sub _register {
    my ($self, $addr) = @_;
    Carp::croak('Data::Shared: composite is read-only') if $self->{readonly};
    Carp::croak("Data::Shared: invalid composite address '" . (defined $addr ? $addr : 'undef') . "' for $self->{node}{spec}")
        unless $self->_valid_address($addr);
    return $self->_with_lock(sub {
        my $existing = $self->_reg_id($addr);
        return $existing if defined $existing;
        my $count = $self->_child_count;
        my $was_parent = $self->_parent_exists($addr);
        my $old_value = $was_parent && !$self->_is_index_parent
            ? Data::Shared::_dispatch_record('get', $self->{parent_record}, [$addr]) : undef;
        my $id = $self->_allocate_id;
        my $ok = eval {
            $self->_parent_register($addr, $id);
            $self->_index_put('s:', $count + 1);
            $self->_index_put('a:' . $addr, $id);
            1;
        };
        my $err = $@;
        unless ($ok) {
            my $clean = eval {
                $self->_index_remove('a:' . $addr);
                $self->_parent_unregister($addr) unless $was_parent;
                Data::Shared::_dispatch_record('set', $self->{parent_record}, [$addr], $old_value)
                    if $was_parent && !$self->_is_index_parent;
                $self->_index_put('s:', $count);
                1;
            };
            die $err . ($clean ? '' : " (rollback: $@)");
        }
        $self->{gen}++;
        return $id;
    }, 1);
}

sub _is_index_parent {
    my ($self) = @_;
    my $key = $self->{node}{resolved}{entry}{key} || '';
    return ($key eq 'kdtree' || $key eq 'graph') ? 1 : 0;
}

sub _parent_exists {
    my ($self, $addr) = @_;
    return defined $self->_reg_id($addr) ? 1 : 0 if $self->_is_index_parent;
    return 0 unless $self->{parent_handle};
    my $r = Data::Shared::_dispatch_record('exists', $self->{parent_record}, [$addr]);
    return $r ? 1 : 0;
}

sub _parent_register {
    my ($self, $addr, $id) = @_;
    return if $self->_is_index_parent;
    return unless $self->{parent_handle};
    my $key = $self->{node}{resolved}{entry}{key} || '';
    if ($key eq 'sortedset') {
        if (!$self->_parent_exists($addr)) {
            Data::Shared::_dispatch_record('set', $self->{parent_record}, [$addr], 0);
        }
    } else {
        Data::Shared::_dispatch_record('set', $self->{parent_record}, [$addr], $id);
    }
    Carp::croak('Data::Shared: cannot register child in parent backend') unless $self->_parent_exists($addr);
    return;
}

sub _parent_unregister {
    my ($self, $addr) = @_;
    return if $self->_is_index_parent;
    return unless $self->{parent_handle};
    if ($self->_parent_exists($addr)) {
        Data::Shared::_dispatch_record('delete', $self->{parent_record}, [$addr]);
        Carp::croak('Data::Shared: cannot unregister child in parent backend') if $self->_parent_exists($addr);
    }
    return;
}

sub _untouch {
    my ($self, $id) = @_;
    return unless exists $self->{lru_prev}{$id};
    my $prev = delete $self->{lru_prev}{$id};
    my $next = delete $self->{lru_next}{$id};
    if (defined $prev) { $self->{lru_next}{$prev} = $next } else { $self->{lru_head} = $next }
    if (defined $next) { $self->{lru_prev}{$next} = $prev } else { $self->{lru_tail} = $prev }
}

sub _touch {
    my ($self, $id) = @_;
    return unless defined $self->{dir};
    return if defined $self->{lru_tail} && $self->{lru_tail} == $id;
    $self->_untouch($id);
    my $tail = $self->{lru_tail};
    $self->{lru_prev}{$id} = $tail;
    $self->{lru_next}{$id} = undef;
    if (defined $tail) { $self->{lru_next}{$tail} = $id } else { $self->{lru_head} = $id }
    $self->{lru_tail} = $id;
}

sub _forget {
    my ($self, $id) = @_;
    $self->_untouch($id);
    return delete $self->{cache}{$id};
}

sub _evict {
    my ($self) = @_;
    return unless defined $self->{dir};
    while (keys(%{ $self->{cache} }) > $self->{node}{cache_size}) {
        $self->_forget($self->{lru_head});
    }
}

sub _open_child {
    my ($self, $root, $addr, $id, $opening, $pending, $cleanup) = @_;
    if (my $rt = $self->{cache}{$id}) {
        $self->_touch($id);
        return $rt;
    }
    my $node = $self->{node}{child};
    my $dir = defined $self->{dir} ? "$self->{dir}/child-$id" : undef;
    # An anonymous root shares the index across a fork but has no file to
    # reopen, so the child is listed and exists while every deeper access
    # failed naming the internal node role ('child') and no cause.
    Carp::croak("Data::Shared: child '" . join('/', '', @{ $self->{path} }, $addr)
        . "' exists in the shared index but belongs to another process; an anonymous"
        . " root has no backing file to reopen it (mount a file-backed root)")
        if $opening && !defined $dir;
    if (defined $dir) {
        Carp::croak("Data::Shared: missing composite child directory '$dir'") if $opening && !-d $dir;
        Carp::croak("Data::Shared: unpublished child storage exists at '$dir'; inspect it before retrying") if !$opening && -e $dir;
        if (!$opening) {
            push @$pending, $dir if $pending;
            require File::Path;
            File::Path::make_path($dir);
        }
    }
    my %mode = (opening => $opening, strict_readonly => $self->{strict_readonly},
        pending_paths => $pending, cleanup => $cleanup, frozen_ok => $self->{_frozen_ok});
    my $rt;
    if ($node->{child}) {
        my $comp = Data::Shared::Composite->new(root => $root, name => $addr, node => $node, dir => $dir,
            path => [ @{ $self->{path} }, $addr ], readonly => $self->{readonly}, %mode);
        $rt = { kind => 'composite', comp => $comp, id => $id, addr => $addr };
    } else {
        my ($handle) = construct_node($dir, $self->{readonly}, $node->{resolved}, 'child', $node->{args}, \%mode);
        my $record = { name => $addr, handle => $handle, entry => $node->{resolved}{entry}
            || { key => $node->{resolved}{class}, dist => 'unknown', path_class => 'map', verbs => {} }, dt => {} };
        $rt = { kind => 'leaf', record => $record, handle => $handle, id => $id, addr => $addr };
    }
    return $rt if $cleanup || $self->{_frozen_ok};
    $self->{cache}{$id} = $rt;
    $self->_touch($id);
    $self->_evict;
    return $rt;
}

sub _existing_child {
    my ($self, $root, $addr) = @_;
    return undef unless $self->_valid_address($addr);
    my $id = $self->_reg_id($addr);
    return undef unless defined $id && $self->_reg_constructed($addr, $id);
    if (my $rt = $self->{cache}{$id}) { $self->_touch($id); return $rt }
    return $self->_with_lock(sub {
        my $current = $self->_reg_id($addr);
        return undef unless defined $current && $self->_reg_constructed($addr, $current);
        return $self->_open_child($root, $addr, $current, 1);
    });
}

sub _ensure_child {
    my ($self, $root, $addr) = @_;
    Carp::croak('Data::Shared: composite is read-only, cannot create a child') if $self->{readonly};
    Carp::croak("Data::Shared: invalid composite address '" . (defined $addr ? $addr : 'undef') . "' for $self->{node}{spec}")
        unless $self->_valid_address($addr);
    my $existing = $self->_existing_child($root, $addr);
    return $existing if $existing;
    return $self->_with_lock(sub {
        my $current = $self->_existing_child($root, $addr);
        return $current if $current;
        my $old_id = $self->_reg_id($addr);
        my $old_marker = $self->{index}->get('c:' . $addr);
        my $was_parent = $self->_parent_exists($addr);
        my $old_value = $was_parent && !$self->_is_index_parent
            ? Data::Shared::_dispatch_record('get', $self->{parent_record}, [$addr]) : undef;
        my $count = $self->_child_count;
        my $id = defined $old_id ? $old_id : $self->_allocate_id;
        my @pending;
        my $rt;
        my $ok = eval {
            $rt = $self->_open_child($root, $addr, $id, 0, \@pending);
            $self->_index_put('c:' . $addr, "id:$id");
            $self->_parent_register($addr, $id);
            $self->_index_put('s:', $count + 1) unless defined $old_id;
            $self->_index_put('a:' . $addr, $id) unless defined $old_id;
            1;
        };
        my $err = $@;
        unless ($ok) {
            $self->_forget($id);
            undef $rt;
            my $clean = eval {
                defined $old_marker ? $self->_index_put('c:' . $addr, $old_marker) : $self->_index_remove('c:' . $addr);
                $self->_index_remove('a:' . $addr) unless defined $old_id;
                $self->_parent_unregister($addr) unless $was_parent;
                Data::Shared::_dispatch_record('set', $self->{parent_record}, [$addr], $old_value)
                    if $was_parent && !$self->_is_index_parent;
                $self->_index_put('s:', $count);
                1;
            };
            my $rollback = $clean ? '' : $@;
            my $files = Data::Shared::_cleanup_paths(\@pending);
            die $err . (length($rollback . $files) ? " (rollback: $rollback $files)" : '');
        }
        $self->{gen}++;
        return $rt;
    }, 1);
}

sub _node_for {
    my ($self, $root, $addr) = @_;
    return Data::Shared::Node->new($root, [ @{ $self->{path} }, $addr ]);
}

sub dispatch_verb {
    my ($self, $root, $verb, $rest, @args) = @_;
    $root = $self->_root($root);
    if (!@$rest) {
        return Data::Shared::Node->new($root, [ @{ $self->{path} } ]) if $verb eq 'get';
        return 1 if $verb eq 'exists';
        Carp::croak("Data::Shared: cannot $verb a composite mount itself; address a child");
    }
    my ($addr, @child_rest) = @$rest;
    if (!@child_rest) {
        return $self->_verb_at_child($root, $verb, $addr, @args);
    }
    if ($verb eq 'exists') {
        my $rt = $self->_existing_child($root, $addr);
        return 0 unless $rt;
        return $self->_child_dispatch_verb($root, $rt, 'exists', \@child_rest, @args);
    }
    if ($verb eq 'get') {
        my $rt = $self->_existing_child($root, $addr);
        return undef unless $rt;
        return $self->_child_dispatch_verb($root, $rt, 'get', \@child_rest, @args);
    }
    if ($verb eq 'delete') {
        my $rt = $self->_existing_child($root, $addr);
        return undef unless $rt;
        return $self->_child_dispatch_verb($root, $rt, 'delete', \@child_rest, @args);
    }
    my $rt = $self->_ensure_child($root, $addr);
    return $self->_child_dispatch_verb($root, $rt, $verb, \@child_rest, @args);
}

sub _verb_at_child {
    my ($self, $root, $verb, $addr, @args) = @_;
    my $key = $self->{node}{resolved}{entry}{key} || '';
    if ($verb eq 'exists') {
        return 0 unless $self->_valid_address($addr);
        return (defined $self->_reg_id($addr) || $self->_parent_exists($addr)) ? 1 : 0;
    }
    if ($verb eq 'get') {
        if ($key eq 'sortedset' && $self->{parent_handle}) {
            return undef unless $self->_valid_address($addr) && $self->_parent_exists($addr);
            return Data::Shared::_dispatch_record('get', $self->{parent_record}, [$addr]);
        }
        # As the exists and delete branches do: an address that cannot be
        # registered needs no index lookup.
        return undef unless $self->_valid_address($addr);
        return undef unless defined $self->_reg_id($addr);
        return $self->_node_for($root, $addr);
    }
    if ($verb eq 'set' || $verb eq 'incr') {
        Carp::croak("Data::Shared: cannot $verb a composite child of $self->{node}{spec}; $verb a path inside it")
            unless $key eq 'sortedset';
        # Before the lock: the leaf's own guard croaks from inside the section,
        # which leaves the interrupted-mutation marker set and costs the next
        # caller a rebuild, for what is only a missing argument.
        Carp::croak("sortedset set needs a score") if $verb eq 'set' && !@args;
        return $self->_with_lock(sub {
            my $old_id = $self->_reg_id($addr);
            my $was_parent = $self->_parent_exists($addr);
            my $score = $was_parent ? Data::Shared::_dispatch_record('get', $self->{parent_record}, [$addr]) : undef;
            my $count = $self->_child_count;
            my $result;
            my $ok = eval {
                $self->_register($addr);
                $result = Data::Shared::_dispatch_record($verb, $self->{parent_record}, [$addr], @args);
                Carp::croak('Data::Shared: parent score operation failed') unless defined $result;
                1;
            };
            my $err = $@;
            unless ($ok) {
                my $clean = eval {
                    $self->_index_remove('a:' . $addr) unless defined $old_id;
                    $self->_index_put('s:', $count);
                    if ($was_parent) { Data::Shared::_dispatch_record('set', $self->{parent_record}, [$addr], $score) }
                    else { $self->_parent_unregister($addr) }
                    1;
                };
                die $err . ($clean ? '' : " (rollback: $@)");
            }
            return $result;
        }, 1);
    }
    if ($verb eq 'delete') {
        return $self->delete_subtree($root, $addr);
    }
    Carp::croak("Data::Shared: operation '$verb' is not supported at a composite child of $self->{node}{spec}");
}

sub _child_dispatch_verb {
    my ($self, $root, $rt, $verb, $child_rest, @args) = @_;
    if ($rt->{kind} eq 'composite') {
        return $rt->{comp}->dispatch_verb($root, $verb, $child_rest, @args);
    }
    return Data::Shared::_dispatch_record($verb, $rt->{record}, $child_rest, @args);
}

sub dispatch_pushpop {
    my ($self, $root, $which, $rest, @args) = @_;
    $root = $self->_root($root);
    Carp::croak("Data::Shared: cannot $which a composite mount itself; address a child") unless @$rest;
    my ($addr, @child_rest) = @$rest;
    my $rt = $self->_ensure_child($root, $addr);
    if ($rt->{kind} eq 'composite') {
        return $rt->{comp}->dispatch_pushpop($root, $which, \@child_rest, @args);
    }
    return Data::Shared::_dispatch_record_pushpop($which, $rt->{record}, \@child_rest, @args);
}

sub dispatch_call {
    my ($self, $root, $rest, $method, @args) = @_;
    $root = $self->_root($root);
    if (!@$rest) {
        # Lifecycle methods belong to the composite, not its parent leaf. Routing
        # them to the parent made 'stats' report the parent's internals and
        # 'destroy' unreachable, and left 'freeze'/'unlink' half-applied: unlink
        # removed parent.shm while the index and children stayed, after which the
        # root could not be reopened at all.
        return $self->$method(@args)
            if $LIFECYCLE_METHOD{$method} && $self->can($method);
        # Not routed, so it would fall through and seal the parent leaf alone:
        # a composite that still accepts writes to children it already has and
        # answers anything else with a raw backend croak.
        Carp::croak("Data::Shared: cannot freeze composite mount '$self->{name}' through call();"
            . " sealing the subtree would seal its child index too. Use \$root->freeze_all")
            if $method eq 'freeze';
        if ($self->{parent_handle} && $self->{parent_handle}->can($method)) {
            return $self->{parent_handle}->$method(@args);
        }
        if ($method eq 'children') {
            my @c = $self->children_at($root, []);
            return wantarray ? @c : \@c;
        }
        if ($method eq 'child_count') {
            return $self->_child_count;
        }
        Carp::croak("Data::Shared: composite mount '" . $self->{name} . "' has no method '$method'");
    }
    my ($addr, @child_rest) = @$rest;
    my $rt = $self->{readonly} ? $self->_existing_child($root, $addr) : $self->_ensure_child($root, $addr);
    Carp::croak('Data::Shared: read-only composite has no constructed child at this path') unless $rt;
    if ($rt->{kind} eq 'composite') {
        return $rt->{comp}->dispatch_call($root, \@child_rest, $method, @args);
    }
    return Data::Shared::_dispatch_record_call($rt->{record}, \@child_rest, $method, @args);
}

sub children_at {
    my ($self, $root, $rest) = @_;
    $root = $self->_root($root);
    if (!@$rest) {
        my @addrs = map { substr($_, 2) } grep { substr($_, 0, 2) eq 'a:' } $self->{index}->keys;
        my @sorted = $self->_key_is_int ? (sort { $a <=> $b } @addrs) : (sort @addrs);
        return @sorted;
    }
    my ($addr, @more) = @$rest;
    my $rt = $self->_existing_child($root, $addr);
    Carp::croak("Data::Shared: no composite child at '" . join('/', @{ $self->{path} }, $addr) . "'")
        unless $rt;
    Carp::croak("Data::Shared: child '$addr' is not composite") unless $rt->{kind} eq 'composite';
    return $rt->{comp}->children_at($root, \@more);
}

sub handle_at {
    my ($self, $root, $rest) = @_;
    $root = $self->_root($root);
    if (!@$rest) {
        return Data::Shared::Node->new($root, [ @{ $self->{path} } ]);
    }
    my ($addr, @more) = @$rest;
    my $rt = $self->_existing_child($root, $addr);
    Carp::croak("Data::Shared: no child at '" . join('/', @{ $self->{path} }, $addr) . "'")
        unless $rt;
    if ($rt->{kind} eq 'composite') {
        return $rt->{comp}->handle_at($root, \@more);
    }
    Carp::croak("Data::Shared: handle() path must name a leaf exactly (got extra components)") if @more;
    return $rt->{handle};
}

sub delete_subtree {
    my ($self, $root, $addr) = @_;
    $root = $self->_root($root);
    Carp::croak('Data::Shared: composite is read-only, cannot delete') if $self->{readonly};
    return undef unless $self->_valid_address($addr);
    return $self->_with_lock(sub {
        my $id = $self->_reg_id($addr);
        my $was_parent = $self->_parent_exists($addr);
        return undef unless defined $id || $was_parent;
        my $cleanup_rt;
        if (defined $id && $self->{node}{child}{child} && $self->_reg_constructed($addr, $id)) {
            $cleanup_rt = $self->_open_child($root, $addr, $id, 1, undef, 1);
        }
        my $marker = $self->{index}->get('c:' . $addr);
        my $count = $self->_child_count;
        my $score = $was_parent && !$self->_is_index_parent
            ? Data::Shared::_dispatch_record('get', $self->{parent_record}, [$addr]) : undef;
        my $ok = eval {
            if (defined $id) {
                $self->_index_remove('a:' . $addr);
                $self->_index_remove('c:' . $addr);
                $self->_index_put('s:', $count - 1);
            }
            $self->_parent_unregister($addr);
            1;
        };
        my $err = $@;
        unless ($ok) {
            my $clean = eval {
                $self->_index_put('c:' . $addr, $marker) if defined $marker;
                $self->_index_put('a:' . $addr, $id) if defined $id;
                $self->_index_put('s:', $count);
                # Only if the unregister actually removed it. Restoring a record
                # that was never touched is the step that fails on a frozen
                # parent, so a consistent delete reported a rollback failure.
                Data::Shared::_dispatch_record('set', $self->{parent_record}, [$addr], $score)
                    if $was_parent && !$self->_is_index_parent && !$self->_parent_exists($addr);
                1;
            };
            die $err . ($clean ? '' : " (rollback: $@)");
        }
        if (defined $id) {
            my $rt = $self->_forget($id) || $cleanup_rt;
            if ($rt) {
                if ($rt->{kind} eq 'composite') { $rt->{comp}->destroy }
                elsif ($rt->{handle}->can('unlink')) { $rt->{handle}->unlink }
            }
            if (defined $self->{dir}) {
                my $cleanup = Data::Shared::_cleanup_paths(["$self->{dir}/child-$id"]);
                Carp::croak("Data::Shared: subtree detached but cleanup failed: $cleanup") if length $cleanup;
            }
        }
        $self->{gen}++;
        return 1;
    }, 1);
}

sub destroy {
    my ($self) = @_;
    Carp::croak('Data::Shared: composite is read-only, cannot destroy') if $self->{readonly};
    # Already gone is the goal state, as it is for a leaf: unlink_all after a
    # native unlink at the mount croaked on the missing directory and left the
    # manifest behind, so the root could not be reopened either.
    return 0 if defined $self->{dir} && !-d $self->{dir};
    return $self->_with_lock(sub {
        my $frozen = $self->{index}->can('frozen') && $self->{index}->frozen;
        if (!$frozen) {
            # Waiters keep their old mapped index after unlink. Retire it before
            # removing directories so they cannot reconstruct a deleted subtree.
            $self->_index_put('x:', 1);
            for my $addr ($self->children_at(undef, [])) {
                my $id = $self->_reg_id($addr);
                my $rt = $self->{cache}{$id};
                if (!$rt && $self->{node}{child}{child} && $self->_reg_constructed($addr, $id)) {
                    $rt = $self->_open_child($self->{root_weak}, $addr, $id, 1, undef, 1);
                }
                $self->_index_remove('a:' . $addr);
                $self->_index_remove('c:' . $addr);
                $self->_forget($id);
                if ($rt) {
                    if ($rt->{kind} eq 'composite') { $rt->{comp}->destroy }
                    elsif ($rt->{handle}->can('unlink')) { $rt->{handle}->unlink }
                }
            }
            $self->_index_put('s:', 0);
        } else {
            # Frozen indexes already reject the mutation marker before any creation.
            for my $rt (values %{ $self->{cache} }) {
                if ($rt->{kind} eq 'composite') { $rt->{comp}->destroy }
                elsif ($rt->{handle}->can('unlink')) { $rt->{handle}->unlink }
            }
        }
        $self->{parent_handle}->unlink if $self->{parent_handle} && $self->{parent_handle}->can('unlink');
        $self->{index}->unlink if $self->{index} && $self->{index}->can('unlink');
        $self->{cache} = {};
        $self->{lru_prev} = {};
        $self->{lru_next} = {};
        delete @{$self}{qw(lru_head lru_tail)};
        if (defined $self->{dir}) {
            my $cleanup = Data::Shared::_cleanup_paths([$self->{dir}]);
            Carp::croak("Data::Shared: cannot remove retired composite: $cleanup") if length $cleanup;
        }
        return 1;
    });
}

sub _sync_once {
    my ($rt) = @_;
    return $rt->{comp}->sync if $rt->{kind} eq 'composite';
    return 0 unless $rt->{handle}->can('sync');
    $rt->{handle}->sync;
    return 1;
}

sub sync {
    my ($self) = @_;
    my $n = 0;
    # Every registered child, as freeze and destroy do, not just the open
    # ones: a child evicted from the cache was silently never flushed, so
    # sync_all did not mean what it says for a composite with more children
    # than its cache. A frozen child has nothing dirty but must stay
    # reachable, hence the tolerant open.
    local $self->{_frozen_ok} = 1;
    my $root = $self->{root_weak};
    if (defined $self->{dir}) {
        # One at a time: holding every child open at once would run a large
        # composite out of descriptors.
        for my $addr ($self->children_at(undef, [])) {
            my $rt = $self->_existing_child($root, $addr) or next;
            $n += _sync_once($rt);
        }
    } else {
        # An anonymous composite has no file to flush, and a child another
        # process created after a fork cannot be mapped here at all, so only
        # the handles this process holds can be flushed.
        $n += _sync_once($_) for values %{ $self->{cache} };
    }
    # Counted unconditionally: the backends' sync returns nothing, so gating
    # on its value never counted the parent or the index at all.
    for my $h ($self->{parent_handle}, $self->{index}) {
        next unless $h && $h->can('sync');
        $h->sync;
        $n++;
    }
    return $n;
}

sub _index_frozen {
    my ($self) = @_;
    return $self->{index} && $self->{index}->can('frozen') && $self->{index}->frozen ? 1 : 0;
}

# The index is frozen last, so a frozen index means the subtree is sealed.
sub frozen {
    my ($self) = @_;
    return 0 unless $self->_index_frozen;
    # Sealed is not the same as shippable: a level whose backend cannot be
    # opened read-only is what makes a shipped copy fail at the first read
    # deep enough to open it.
    for (my $node = $self->{node}; $node; $node = $node->{child}) {
        return 0 unless eval { Data::Shared::Storage::check_readonly($node->{resolved}); 1 };
    }
    return 1;
}

sub freeze {
    my ($self) = @_;
    Carp::croak("Data::Shared: cannot freeze a read-only composite") if $self->{readonly};
    return $self->_with_lock(sub {
        my $root = $self->{root_weak};
        my $n = 0;
        # A child frozen earlier (directly, or by an interrupted freeze) cannot
        # be reopened writable, and an evicted one has to be reopened to be
        # frozen. Without this the walk croaked on it and the store could end
        # up frozen in part: readable neither writably nor read-only.
        local $self->{_frozen_ok} = 1;
        for my $addr ($self->children_at(undef, [])) {
            my $rt = $self->_existing_child($root, $addr) or next;
            if ($rt->{kind} eq 'composite') { $n += $rt->{comp}->freeze }
            else { $n += _freeze_once($rt->{handle}) }
        }
        $n += _freeze_once($self->{parent_handle});
        $n += _freeze_once($self->{index});
        return $n;
    });
}

sub unlink {
    my ($self) = @_;
    return $self->destroy;
}

sub stats {
    my ($self) = @_;
    my $root = $self->{root_weak};
    my %children;
    for my $id (sort { $a <=> $b } keys %{ $self->{cache} }) {
        my $rt = $self->{cache}{$id};
        $children{ $rt->{addr} } = $rt->{kind} eq 'composite' ? $rt->{comp}->stats
            : ($rt->{handle}->can('stats') ? $rt->{handle}->stats : { class => ref $rt->{handle} });
    }
    return {
        class => 'Data::Shared::Composite',
        spec => $self->{node}{spec},
        children => $self->_child_count,
        open => scalar keys %{ $self->{cache} },
        child_stats => \%children,
    };
}

1;

__END__

=head1 NAME

Data::Shared::Composite - Runtime for composite Data::Shared mounts

=head1 DESCRIPTION

Internal to L<Data::Shared>; not a public API. A composite mount
keeps one child instance per parent address: children are allocated
through a hidden registry, constructed lazily on first write, opened
on demand from per-child storage, and cached with LRU eviction.
Reads of a missing child never create one. See the C<DEEP PATHS>
section of L<Data::Shared>.

Lifecycle mutations are serialized through allocation, construction,
publication, and deletion. Exception rollback preserves existing scores and
reservations. Shared counts and cache-order updates take constant time.
Legacy readiness flags remain readable. An interrupted mutation leaves a
marker, and the count is rebuilt from it on the next writable open or lock.
Freezing and flushing walk every registered child, reopening an evicted one
read-only where it is already sealed. Unpublished files require explicit recovery;
the module does not implement a power-loss transaction journal.

=cut
