package Data::Shared;
use strict;
use warnings;

our $VERSION = '0.01';

# Mount-time croaks run inside Manifest::with_lock, so without this Carp blames
# the sibling internals instead of the caller's mount() line.
our @CARP_NOT = qw(Data::Shared Data::Shared::Manifest Data::Shared::Storage
                   Data::Shared::Composite);

use Carp ();
use overload ();
use JSON::PP ();
use Scalar::Util qw(blessed refaddr weaken);
use parent 'Exporter';
our @EXPORT_OK = qw(
    shared_get shared_set shared_delete shared_exists shared_incr
    shared_call shared_push shared_pop
    shareda_get shareda_set shareda_delete shareda_exists shareda_incr
    shareda_call shareda_push shareda_pop
    shared_compile
    sharedc_get sharedc_set sharedc_delete sharedc_exists sharedc_incr
    sharedc_call sharedc_push sharedc_pop
    shared_node shared_children
);

use Data::Shared::Registry ();
use Data::Shared::Compiled ();
use Data::Shared::Node ();
use Data::Shared::Composite ();
use Data::Shared::Manifest ();
use Data::Shared::Storage ();
use Data::Shared::Adapter::Map ();
use Data::Shared::Adapter::Set ();
use Data::Shared::Adapter::Indexed ();
use Data::Shared::Adapter::Queue ();
use Data::Shared::Adapter::Sketch ();
use Data::Shared::Adapter::Sync ();

my %ADAPTER_FOR = (
    map     => 'Data::Shared::Adapter::Map',
    set     => 'Data::Shared::Adapter::Set',
    indexed => 'Data::Shared::Adapter::Indexed',
    queue   => 'Data::Shared::Adapter::Queue',
    sketch  => 'Data::Shared::Adapter::Sketch',
    sync    => 'Data::Shared::Adapter::Sync',
);

sub CLONE_SKIP { 1 }

sub import {
    my $class = shift;
    my @args = @_;
    for my $a (@args) {
        if ($a eq ':keywords') {
            Carp::croak("Data::Shared: ':keywords' syntax is not available; use the shared_* functions");
        }
    }
    if (@args) {
        $class->export_to_level(1, $class, @args);
    }
}

sub _parse_string_path {
    my ($path) = @_;
    Carp::croak("path must be a defined string") unless defined $path;
    Carp::croak("path must not be a reference") if ref $path;
    return [] if $path eq '' || $path eq '/';
    my $p = $path;
    $p =~ s{^/+}{};   # one slash left an empty leading component for "//a/b"
    return [] if $p eq '';
    return [ split m{/}, $p ] if index($p, '//') < 0 && substr($p, -1) ne '/';
    return [ grep { length } split m{/}, $p ];
}

sub _parse_array_path {
    my ($aref) = @_;
    Carp::croak("array path must be an ARRAY reference")
        unless ref $aref eq 'ARRAY';
    return _check_components([ @$aref ]);
}

# The string tier refuses an undef or reference path outright. An array
# component got through unchecked, so undef addressed the empty-string key and
# a reference addressed its own stringified address -- a different key every
# run -- both reported as a successful write. An object that overloads
# stringification is allowed, since the string tier accepts the spelling it
# produces, but it is resolved here and now: kept as a reference, a mutable
# object addressed a different key on every use of the same compiled path, and
# a handler returning undef addressed the empty-string key -- the very case
# this check exists for. Every caller passes a fresh copy of the list, so
# replacing the component in place cannot reach the caller's array.
sub _check_components {
    my ($components) = @_;
    for my $c (@$components) {
        next if defined $c && !ref $c;
        my $stringify = defined $c && overload::Method($c, '""');
        Carp::croak("path component must be a defined string") unless $stringify;
        my $string = $stringify->($c, undef, '');
        Carp::croak("path component must be a defined string")
            if !defined $string || ref $string;
        $c = $string;
    }
    return $components;
}

sub _check_root {
    my ($root) = @_;
    Carp::croak("first argument must be a Data::Shared root")
        unless blessed($root) && $root->isa('Data::Shared');
    return $root;
}

sub _resolve {
    my ($root, $components) = @_;
    my $mounts = $root->{mounts};
    if (!$root->{_nested}) {
        if (my $m = $mounts->{ $components->[0] }) {
            my @rest = @{$components}[1 .. $#$components];
            return ($components->[0], $m, \@rest);
        }
    } else {
        for (my $n = scalar @$components; $n >= 1; $n--) {
            my $candidate = join('/', @{$components}[0 .. $n - 1]);
            if (my $m = $mounts->{$candidate}) {
                my @rest = @{$components}[$n .. $#$components];
                return ($candidate, $m, \@rest);
            }
        }
    }
    my $shown = '/' . join('/', @$components);
    Carp::croak("Data::Shared: no mount matches path '$shown' (mounts: "
        . join(', ', sort keys %$mounts) . ")");
}

sub _verb_code {
    my ($mount, $verb) = @_;
    my $dt = $mount->{dt} ||= {};
    return $dt->{$verb} if exists $dt->{$verb};
    my $adapter = _adapter_for($mount->{entry});
    my $code = $adapter->make_verb($verb, $mount->{handle}, $mount->{entry});
    $dt->{$verb} = $code;
    return $code;
}

sub _pushpop_code {
    my ($mount, $which) = @_;
    my $key = "_pp_$which";
    my $dt = $mount->{dt} ||= {};
    return $dt->{$key} if exists $dt->{$key};
    my $adapter = _adapter_for($mount->{entry});
    my $maker = $which eq 'push' ? 'make_push' : 'make_pop';
    my $code = $adapter->$maker($mount->{handle}, $mount->{entry});
    $dt->{$key} = $code;
    return $code;
}

sub _adapter_for {
    my ($entry) = @_;
    my $pc = $entry->{path_class} || 'map';
    return $ADAPTER_FOR{$pc} || $ADAPTER_FOR{map};
}

my %MUTATING = map { $_ => 1 } qw(set delete incr push pop);

sub _dispatch_record {
    my ($verb, $mount, $rest, @args) = @_;
    my $code = _verb_code($mount, $verb);
    if (!$code) {
        my $adapter = _adapter_for($mount->{entry});
        if ($verb eq 'exists') {
            my $r = $adapter->perform($verb, $mount->{handle}, $mount->{entry}, $rest, @args);
            return $r ? 1 : 0;
        }
        return $adapter->perform($verb, $mount->{handle}, $mount->{entry}, $rest, @args);
    }
    if ($verb eq 'exists') {
        my $r = $code->($rest, @args);
        return $r ? 1 : 0;
    }
    return $code->($rest, @args);
}

sub _dispatch_record_pushpop {
    my ($which, $mount, $rest, @args) = @_;
    my $code = _pushpop_code($mount, $which);
    if (!$code) {
        my $adapter = _adapter_for($mount->{entry});
        my $method = $which eq 'push' ? 'perform_push' : 'perform_pop';
        return $adapter->$method($mount->{handle}, $mount->{entry}, $rest, @args);
    }
    return $code->($rest, @args);
}

sub _dispatch_record_call {
    my ($mount, $rest, $method, @args) = @_;
    my $handle = $mount->{handle};
    my $label = defined $mount->{name} ? "mount '$mount->{name}'" : 'handle';
    Carp::croak("Data::Shared: $label (" . ref($handle) . ") has no method '$method'")
        unless $handle->can($method);
    my @full = (@$rest, @args);
    return $handle->$method(@full);
}

sub _construct_with {
    my ($dir, $readonly, $resolved, $name, $args, $mode) = @_;
    my $tmp = bless { dir => $dir, mounts => {}, readonly => $readonly ? 1 : 0,
        _opening => $mode->{opening}, strict_readonly => $mode->{strict_readonly},
        _cleanup => $mode->{cleanup}, _frozen_ok => $mode->{frozen_ok},
        _pending_paths => $mode->{pending_paths} }, __PACKAGE__;
    return $tmp->_construct($resolved, $name, @$args);
}

sub _dispatch {
    my ($verb, $root, $components, @args) = @_;
    _check_root($root);
    if (!@$components) {
        return $root if $verb eq 'get';
        return 1     if $verb eq 'exists';
        Carp::croak("Data::Shared: cannot $verb the root");
    }
    if ($root->{readonly} && $MUTATING{$verb}) {
        Carp::croak("Data::Shared: root is read-only, cannot $verb");
    }
    my ($name, $mount, $rest) = _resolve($root, $components);
    if (my $comp = $mount->{composite}) {
        return $comp->dispatch_verb($root, $verb, $rest, @args);
    }
    return _dispatch_record($verb, $mount, $rest, @args);
}

sub _dispatch_pushpop {
    my ($which, $root, $components, @args) = @_;
    _check_root($root);
    Carp::croak("Data::Shared: cannot $which the root") unless @$components;
    if ($root->{readonly}) {
        Carp::croak("Data::Shared: root is read-only, cannot $which");
    }
    my ($name, $mount, $rest) = _resolve($root, $components);
    if (my $comp = $mount->{composite}) {
        return $comp->dispatch_pushpop($root, $which, $rest, @args);
    }
    return _dispatch_record_pushpop($which, $mount, $rest, @args);
}

sub _dispatch_call {
    my ($root, $components, $method, @args) = @_;
    _check_root($root);
    Carp::croak("shared_call requires a method name") unless defined $method && length $method;
    _check_native_call($root, $method);
    Carp::croak("shared_call path must name a mount") unless @$components;
    my ($name, $mount, $rest) = _resolve($root, $components);
    if (my $comp = $mount->{composite}) {
        return $comp->dispatch_call($root, $rest, $method, @args);
    }
    my $handle = $mount->{handle};
    Carp::croak("Data::Shared: mount '$name' (" . ref($handle) . ") has no method '$method'")
        unless $handle->can($method);
    my @full = (@$rest, @args);
    return $handle->$method(@full);
}

sub shared_get    { my ($r, $p, @a) = @_; return _dispatch('get',    $r, _parse_string_path($p), @a) }
sub shared_set    { my ($r, $p, @a) = @_; return _dispatch('set',    $r, _parse_string_path($p), @a) }
sub shared_delete { my ($r, $p, @a) = @_; return _dispatch('delete', $r, _parse_string_path($p), @a) }
sub shared_exists { my ($r, $p, @a) = @_; return _dispatch('exists', $r, _parse_string_path($p), @a) }
sub shared_incr   { my ($r, $p, @a) = @_; return _dispatch('incr',   $r, _parse_string_path($p), @a) }
sub shared_push   { my ($r, $p, @a) = @_; return _dispatch_pushpop('push', $r, _parse_string_path($p), @a) }
sub shared_pop    { my ($r, $p, @a) = @_; return _dispatch_pushpop('pop',  $r, _parse_string_path($p), @a) }
sub shared_call   { my ($r, $p, $m, @a) = @_; return _dispatch_call($r, _parse_string_path($p), $m, @a) }

sub shareda_get    { my ($r, $p, @a) = @_; return _dispatch('get',    $r, _parse_array_path($p), @a) }
sub shareda_set    { my ($r, $p, @a) = @_; return _dispatch('set',    $r, _parse_array_path($p), @a) }
sub shareda_delete { my ($r, $p, @a) = @_; return _dispatch('delete', $r, _parse_array_path($p), @a) }
sub shareda_exists { my ($r, $p, @a) = @_; return _dispatch('exists', $r, _parse_array_path($p), @a) }
sub shareda_incr   { my ($r, $p, @a) = @_; return _dispatch('incr',   $r, _parse_array_path($p), @a) }
sub shareda_push   { my ($r, $p, @a) = @_; return _dispatch_pushpop('push', $r, _parse_array_path($p), @a) }
sub shareda_pop    { my ($r, $p, @a) = @_; return _dispatch_pushpop('pop',  $r, _parse_array_path($p), @a) }
sub shareda_call   { my ($r, $p, $m, @a) = @_; return _dispatch_call($r, _parse_array_path($p), $m, @a) }

sub shared_compile {
    my ($path) = @_;
    my ($components, $is_array);
    if (ref $path eq 'ARRAY') {
        $components = _check_components([ @$path ]);
        $is_array = 1;
    } else {
        $components = _parse_string_path($path);
        $is_array = 0;
    }
    return bless { components => $components, raw => ($is_array ? [ @$path ] : $path), is_array => $is_array },
        'Data::Shared::Compiled';
}

sub _check_compiled {
    my ($cp) = @_;
    Carp::croak("not a compiled path (use shared_compile)")
        unless blessed($cp) && $cp->isa('Data::Shared::Compiled');
    return $cp->{components};
}

sub _compiled_code {
    my ($root, $cp, $kind, $extra) = @_;
    my $key = defined $extra ? "call:$extra" : $kind;
    my $cache = $cp->{_bc} ||= {};
    my $gen = $root->{gen} || 0;
    my $addr = refaddr($root);
    my $hit = $cache->{$key};
    # $hit->[2] is weakened, so check it survived rather than returning undef
    # as the bound code.
    return $hit->[2] if $hit && $hit->[2] && $hit->[0] == $addr && $hit->[1] == $gen && $hit->[3] && $hit->[3] == $root;
    my $components = $cp->{components};
    Carp::croak("Data::Shared: cannot use a compiled root path this way") unless @$components;
    my ($name, $mount, $rest) = _resolve($root, $components);
    if (my $comp = $mount->{composite}) {
        my $weak = $root;
        weaken($weak);
        my $bound;
        if ($kind eq 'call') {
            $bound = sub { my @a = @_; my $r = $weak or Carp::croak("Data::Shared: root has gone away"); return $comp->dispatch_call($r, $rest, $extra, @a) };
        } elsif ($kind eq 'push' || $kind eq 'pop') {
            $bound = sub { my @a = @_; my $r = $weak or Carp::croak("Data::Shared: root has gone away"); return $comp->dispatch_pushpop($r, $kind, $rest, @a) };
        } else {
            $bound = sub { my @a = @_; my $r = $weak or Carp::croak("Data::Shared: root has gone away"); return $comp->dispatch_verb($r, $kind, $rest, @a) };
        }
        _cache_compiled($root, $cp, $key, $bound);
        return $bound;
    }
    my $adapter = _adapter_for($mount->{entry});
    my $bound;
    if ($kind eq 'call') {
        my $handle = $mount->{handle};
        Carp::croak("Data::Shared: mount '$name' (" . ref($handle) . ") has no method '$extra'")
            unless $handle->can($extra);
        my $method = $handle->can($extra);
        $bound = sub { my @a = @_; return $handle->$method(@$rest, @a) };
    } elsif ($kind eq 'push' || $kind eq 'pop') {
        my $maker = $kind eq 'push' ? 'make_bound_push' : 'make_bound_pop';
        $bound = $adapter->$maker($mount->{handle}, $mount->{entry}, $rest);
        if (!$bound) {
            my $method = $kind eq 'push' ? 'perform_push' : 'perform_pop';
            $bound = sub { my @a = @_; return $adapter->$method($mount->{handle}, $mount->{entry}, $rest, @a) };
        }
    } else {
        $bound = $adapter->make_bound($kind, $mount->{handle}, $mount->{entry}, $rest);
        if (!$bound) {
            $bound = sub { my @a = @_; return $adapter->perform($kind, $mount->{handle}, $mount->{entry}, $rest, @a) };
        }
    }
    _cache_compiled($root, $cp, $key, $bound);
    return $bound;
}

sub _cache_compiled {
    my ($root, $cp, $key, $bound) = @_;
    my $id = refaddr($cp);
    if (my $old = $cp->{_bc}{$key}) {
        if (my $owner = $old->[3]) {
            delete $owner->{_compiled}{$id}{$key};
            delete $owner->{_compiled}{$id} unless keys %{ $owner->{_compiled}{$id} || {} };
        }
    }
    $root->{_compiled}{$id}{$key} = $bound;
    my $entry = $cp->{_bc}{$key} = [refaddr($root), $root->{gen} || 0, $bound, $root];
    weaken($entry->[2]);
    weaken($entry->[3]);
}

sub _check_native_call {
    my ($root, $method) = @_;
    Carp::croak("Data::Shared: root is read-only, cannot call '$method'")
        if $root->{readonly} && ($method eq 'unlink' || $method eq 'destroy' || $method eq 'freeze');
}

sub _dispatch_compiled {
    my ($verb, $root, $cp, @args) = @_;
    Carp::croak("first argument must be a Data::Shared root")
        unless (ref $root eq 'Data::Shared') || (blessed($root) && $root->isa('Data::Shared'));
    Carp::croak("not a compiled path (use shared_compile)")
        unless (ref $cp eq 'Data::Shared::Compiled') || (blessed($cp) && $cp->isa('Data::Shared::Compiled'));
    if (!@{ $cp->{components} }) {
        return $root if $verb eq 'get';
        return 1     if $verb eq 'exists';
        Carp::croak("Data::Shared: cannot $verb the root");
    }
    if ($root->{readonly} && $MUTATING{$verb}) {
        Carp::croak("Data::Shared: root is read-only, cannot $verb");
    }
    my $bound = _compiled_code($root, $cp, $verb);
    if ($verb eq 'exists') {
        my $r = $bound->(@args);
        return $r ? 1 : 0;
    }
    return $bound->(@args);
}

sub _dispatch_compiled_pushpop {
    my ($which, $root, $cp, @args) = @_;
    Carp::croak("first argument must be a Data::Shared root")
        unless (ref $root eq 'Data::Shared') || (blessed($root) && $root->isa('Data::Shared'));
    Carp::croak("not a compiled path (use shared_compile)")
        unless (ref $cp eq 'Data::Shared::Compiled') || (blessed($cp) && $cp->isa('Data::Shared::Compiled'));
    Carp::croak("Data::Shared: cannot $which the root") unless @{ $cp->{components} };
    Carp::croak("Data::Shared: root is read-only, cannot $which") if $root->{readonly};
    my $bound = _compiled_code($root, $cp, $which);
    return $bound->(@args);
}

# A live cache entry already proves this path resolved against this root at this
# generation, so a hit needs no re-validation beyond identity and generation, and
# the remaining argument list can be handed to the bound closure without being
# copied again. Anything else falls through to the full dispatch below. Mutating
# verbs re-check readonly because this path skips the gate in
# _dispatch_compiled; the cache is keyed per verb and a read-only root never
# reaches _compiled_code for a mutating verb, so the check is defensive.
sub _bound_hit {
    my ($root, $cp, $key) = @_;
    return undef unless ref $root && ref $cp eq 'Data::Shared::Compiled';
    my $hit = $cp->{_bc} && $cp->{_bc}{$key} or return undef;
    return undef unless $hit->[3] && $hit->[3] == $root && $hit->[1] == ($root->{gen} || 0);
    return $hit->[2];
}

# @_ is never modified here: the no-parens forms `&name` and `&$ref` share the
# caller's @_, so splicing it would delete the caller's own arguments on every
# warm call. A slice is only built when there are arguments to forward, which
# keeps the argument-less verbs free.
sub sharedc_get {
    if (my $code = _bound_hit($_[0], $_[1], 'get')) {
        return @_ > 2 ? $code->(@_[2 .. $#_]) : $code->();
    }
    my ($r, $cp, @a) = @_; return _dispatch_compiled('get', $r, $cp, @a);
}

sub sharedc_exists {
    if (my $code = _bound_hit($_[0], $_[1], 'exists')) {
        my $r = @_ > 2 ? $code->(@_[2 .. $#_]) : $code->();
        return $r ? 1 : 0;
    }
    my ($r, $cp, @a) = @_; return _dispatch_compiled('exists', $r, $cp, @a);
}

sub sharedc_set {
    if (my $code = _bound_hit($_[0], $_[1], 'set')) {
        return @_ > 2 ? $code->(@_[2 .. $#_]) : $code->() unless $_[0]{readonly};
    }
    my ($r, $cp, @a) = @_; return _dispatch_compiled('set', $r, $cp, @a);
}

sub sharedc_delete {
    if (my $code = _bound_hit($_[0], $_[1], 'delete')) {
        return @_ > 2 ? $code->(@_[2 .. $#_]) : $code->() unless $_[0]{readonly};
    }
    my ($r, $cp, @a) = @_; return _dispatch_compiled('delete', $r, $cp, @a);
}

sub sharedc_incr {
    if (my $code = _bound_hit($_[0], $_[1], 'incr')) {
        return @_ > 2 ? $code->(@_[2 .. $#_]) : $code->() unless $_[0]{readonly};
    }
    my ($r, $cp, @a) = @_; return _dispatch_compiled('incr', $r, $cp, @a);
}

sub sharedc_push {
    if (my $code = _bound_hit($_[0], $_[1], 'push')) {
        return @_ > 2 ? $code->(@_[2 .. $#_]) : $code->() unless $_[0]{readonly};
    }
    my ($r, $cp, @a) = @_; return _dispatch_compiled_pushpop('push', $r, $cp, @a);
}

sub sharedc_pop {
    if (my $code = _bound_hit($_[0], $_[1], 'pop')) {
        return @_ > 2 ? $code->(@_[2 .. $#_]) : $code->() unless $_[0]{readonly};
    }
    my ($r, $cp, @a) = @_; return _dispatch_compiled_pushpop('pop', $r, $cp, @a);
}
sub sharedc_call {
    my ($r, $cp, $m, @a) = @_;
    _check_root($r);
    _check_compiled($cp);
    Carp::croak("shared_call requires a method name") unless defined $m && length $m;
    _check_native_call($r, $m);
    my $bound = _compiled_code($r, $cp, 'call', $m);
    return $bound->(@a);
}

sub registry { return Data::Shared::Registry::registry() }
sub available_types { return Data::Shared::Registry::keys_list() }

sub _empty_root {
    my ($class, $dir, %opt) = @_;
    return bless { dir => $dir, mounts => {}, order => [], readonly => $opt{readonly} ? 1 : 0,
        strict_readonly => $opt{strict} ? 1 : 0, gen => 0, _nested => 0,
        _revision => 0, _compiled => {} }, $class;
}

sub new {
    my ($class, $dir) = @_;
    my $self = _empty_root($class, $dir);
    if (defined $dir) {
        require File::Path;
        # 0700: the backing files are owner-only, so a group-writable root would
        # just let another user unlink the manifest. A directory that already
        # exists keeps its own mode, so sharing stays an explicit choice.
        File::Path::make_path($dir, { mode => 0700 }) unless -d $dir;
        Carp::croak("Data::Shared: cannot create directory '$dir'") unless -d $dir;
        Data::Shared::Manifest::with_lock($self, 1, sub {
            if (-e $self->manifest_path) { $self->_replay_manifest }
            else { $self->_write_manifest }
        });
    }
    return $self;
}

sub _open_root {
    my ($class, $dir, %opt) = @_;
    Carp::croak('Data::Shared->open requires a directory') unless defined $dir;
    Carp::croak("Data::Shared: directory '$dir' does not exist") unless -d $dir;
    my $self = _empty_root($class, $dir, %opt);
    Data::Shared::Manifest::with_lock($self, 0, sub { $self->_replay_manifest });
    return $self;
}

sub open { my ($class, $dir) = @_; return _open_root($class, $dir) }

sub open_readonly {
    my ($class, $dir, %opt) = @_;
    Carp::croak('Data::Shared: unknown read-only option') if grep { $_ ne 'strict' } keys %opt;
    return _open_root($class, $dir, readonly => 1, %opt);
}

sub dir      { return $_[0]{dir} }
sub readonly { return $_[0]{readonly} ? 1 : 0 }
sub manifest_path { my ($s) = @_; return defined $s->{dir} ? "$s->{dir}/manifest.json" : undef }

sub _require_class {
    my ($cls, $dist) = @_;
    (my $file = $cls) =~ s{::}{/}g;
    $file .= '.pm';
    eval { require $file };
    if (my $e = $@) {
        # Name the dist, not just the module: with the leaves recommended rather
        # than required this is the first error most users meet. The caller
        # supplies it, because a variant class such as
        # Data::HashMap::Shared::II lives in the Data-HashMap-Shared dist and
        # the name cannot be derived. The @INC dump buries the actionable part.
        $e =~ s/ \(\@INC.*//s;
        $e =~ s/\s+\z//;
        my $how = defined $dist
            ? "install the $dist dist"
            : "install the dist providing $cls";
        Carp::croak("Data::Shared: backend $cls is not available; $how: $e");
    }
    return 1;
}

sub _file_for {
    my ($self, $name) = @_;
    my $safe = $name;
    $safe =~ s{/}{__}g;
    $safe =~ s{[^A-Za-z0-9_.-]}{_}g;
    return "$self->{dir}/$safe.shm";
}

sub _check_storage_paths {
    my ($self, $name, @paths) = @_;
    return unless keys %{ $self->{mounts} };
    require Cwd;
    require File::Spec;
    for my $path (grep { defined $_ } @paths) {
        my $abs = $self->_abs_path($path);
        for my $mount (values %{ $self->{mounts} }) {
            for my $used (@{ $mount->{storage_paths} || [] }) {
                my $used_abs = $self->_abs_path($used);
                Carp::croak("Data::Shared: backing path '$path' for mount '$name' is already used by mount '$mount->{name}'")
                    if $abs eq $used_abs || ($mount->{composite} && index($abs, "$used_abs/") == 0);
            }
        }
    }
    return;
}

# abs_path lstats every component, and the collision check walks every
# installed path for every new one. Cached for one manifest operation only:
# held longer, a symlink retargeted between two mounts hid a real collision,
# and the store then failed to reopen because replay resolves afresh. So a
# replay resolves each path once, while mounting one at a time still re-resolves
# the installed ones -- accepted, since republishing the manifest dominates
# that path anyway (see the mount-count note under PERFORMANCE).
sub _abs_path {
    my ($self, $path) = @_;
    my $hit = $self->{_abs_cache}{$path};
    return $hit if defined $hit;
    require Cwd;
    require File::Spec;
    my $abs = Cwd::abs_path($path);
    return $self->{_abs_cache}{$path} = $abs if defined $abs;
    return File::Spec->rel2abs($path);
}

sub _track_paths {
    my ($self, @paths) = @_;
    return unless $self->{_pending_paths};
    push @{ $self->{_pending_paths} }, grep { defined $_ && !-e $_ } @paths;
}

sub _cleanup_paths {
    my ($paths) = @_;
    my @errors;
    my %seen;
    for my $path (reverse @$paths) {
        next if $seen{$path}++ || !-e $path;
        if (-d $path && !-l $path) {
            require File::Path;
            my $errors;
            File::Path::remove_tree($path, { error => \$errors });
            push @errors, "cannot clean '$path'" if @$errors;
        } else {
            CORE::unlink($path) or push @errors, "cannot clean '$path': $!";
        }
    }
    return join('; ', @errors);
}

sub _manifest_data {
    my ($self) = @_;
    my @mounts;
    for my $name (@{ $self->{order} }) {
        my $m = $self->{mounts}{$name} or next;
        next if $m->{transient};
        push @mounts, { name => $name, spec => $m->{spec}, args => $m->{args} };
    }
    return { version => 1, revision => $self->{_revision}, mounts => \@mounts };
}

sub _write_manifest {
    my ($self) = @_;
    return unless defined $self->{dir};
    Carp::croak('Data::Shared: root is read-only, cannot write manifest') if $self->{readonly};
    my $data = $self->_manifest_data;
    $self->{_manifest_stamp} = Data::Shared::Manifest::write($self->manifest_path, $data);
    return 1;
}

sub _assert_revision {
    my ($self) = @_;
    return unless defined $self->{dir};
    # Say which it is: after unlink_all the manifest is gone on purpose, and
    # reporting that it cannot be read reads as corruption.
    Carp::croak('Data::Shared: this store was unlinked; create or open a root again')
        if defined $self->{_manifest_stamp} && !-e $self->manifest_path;
    my ($current, $stamp) = Data::Shared::Manifest::read($self->manifest_path);
    Carp::croak('Data::Shared: stale manifest revision; reopen the root before changing mounts')
        unless $current->{revision} == $self->{_revision} && $stamp eq $self->{_manifest_stamp};
}

sub _invalidate_compiled {
    my ($self) = @_;
    $self->{gen}++;
    $self->{_compiled} = {};
}

sub _mutate {
    my ($self, $code) = @_;
    Carp::croak('Data::Shared: root is read-only, cannot change mounts') if $self->{readonly};
    Carp::croak('Data::Shared: nested mount mutations are not supported') if $self->{_mutating};
    return Data::Shared::Manifest::with_lock($self, 1, sub {
        $self->_assert_revision;
        local $self->{_mutating} = 1;
        local $self->{_pending_paths} = [];
        local $self->{_abs_cache} = {};
        local $self->{_changed} = 0;
        my ($mounts, $order, $nested, $revision, $stamp) =
            ({ %{ $self->{mounts} } }, [ @{ $self->{order} } ], $self->{_nested}, $self->{_revision}, $self->{_manifest_stamp});
        my $ret;
        my $ok = eval {
            $ret = $code->();
            if ($self->{_changed}) {
                $self->{_revision}++;
                $self->_write_manifest;
            }
            1;
        };
        my $err = $@;
        if (!$ok) {
            @{$self}{qw(mounts order _nested _revision _manifest_stamp)} = ($mounts, $order, $nested, $revision, $stamp);
            my $cleanup = _cleanup_paths($self->{_pending_paths});
            # An exception object must reach the caller intact; the rewrite and
            # re-croak below would stringify it.
            die $err if ref $err;
            # $err already carries "at FILE line N."; re-croaking it appended a
            # second copy. Strip it and let Carp add the caller's location once.
            $err =~ s/\s*\bat .+ line \d+\.?\s*\z//s;
            Carp::croak($err . (length $cleanup ? " (rollback: $cleanup)" : ''));
        }
        $self->_invalidate_compiled if $self->{_changed};
        return $ret;
    });
}

sub _recipe {
    my ($self, $name, $spec, @args) = @_;
    Carp::croak('mount requires a name') unless defined $name && !ref $name && length $name;
    $name =~ s{^/+}{};
    $name =~ s{/+$}{};
    Carp::croak('mount requires a canonical name')
        unless length $name && $name ne '.' && $name ne '..' && index($name, '//') < 0 && index($name, "\0") < 0;
    Carp::croak("mount '$name' requires a spec, handle, or coderef") unless defined $spec;
    if (blessed($spec) || ref $spec eq 'CODE') {
        return { name => $name, source => $spec, kind => 'transient', transient => 1, storage_paths => [] };
    }
    my ($copy, $serializable) = Data::Shared::Manifest::snapshot([$spec, \@args]);
    ($spec, my $args) = @$copy;
    my $recipe = { name => $name, source => $spec, spec => $spec, manifest_args => $args,
        transient => !$serializable, kind => 'leaf' };
    if (ref $spec eq 'ARRAY' || (ref $spec eq 'HASH' && exists $spec->{child})) {
        my $node = Data::Shared::Composite::parse_node($spec);
        $recipe->{node} = $node;
        $recipe->{resolved} = $node->{resolved};
        $recipe->{args} = Data::Shared::Composite::_constructor_args($node->{resolved}, $node->{args});
        $recipe->{manifest_args} = [];
        if ($node->{child}) {
            $recipe->{kind} = 'composite';
            if (defined $self->{dir}) {
                my $safe = $name;
                $safe =~ s{/}{__}g;
                $safe =~ s{[^A-Za-z0-9_.-]}{_}g;
                $recipe->{dir} = "$self->{dir}/.children/$safe";
            }
        }
    } elsif (ref $spec eq 'HASH') {
        my $inner = $spec->{spec} // $spec->{class} // $spec->{key};
        Carp::croak("mount '$name' hashref spec needs spec/class/key") unless defined $inner;
        $recipe->{resolved} = Data::Shared::Registry::resolve_spec($inner);
        Carp::croak("Data::Shared: unknown mount spec '$inner'") unless $recipe->{resolved};
        if (exists $spec->{ctor}) {
            Carp::croak('Data::Shared: invalid constructor name')
                unless defined $spec->{ctor} && !ref $spec->{ctor} && $spec->{ctor} =~ /\A[A-Za-z_]\w*\z/;
            $recipe->{resolved}{ctor} = $spec->{ctor};
        }
        Carp::croak('Data::Shared: constructor args must be an ARRAY reference')
            if exists $spec->{args} && ref $spec->{args} ne 'ARRAY';
        $recipe->{args} = exists $spec->{args} ? $spec->{args} : $args;
        $recipe->{manifest_args} = [] if exists $spec->{args};
    } else {
        $recipe->{resolved} = Data::Shared::Registry::resolve_spec($spec);
        Carp::croak("Data::Shared: unknown mount spec '$spec' (see Data::Shared::Registry)") unless $recipe->{resolved};
        $recipe->{args} = $args;
    }
    if ($recipe->{kind} eq 'composite') {
        Data::Shared::Composite::_preflight($self, $recipe->{node}, $recipe->{dir}, $self->{_opening});
        $recipe->{storage_paths} = [defined $recipe->{dir} ? $recipe->{dir} : ()];
    } else {
        $recipe->{plan} = Data::Shared::Storage::plan($self, $recipe->{resolved}, $name, $recipe->{args});
        Data::Shared::Storage::require_files($recipe->{plan}) if $self->{_opening};
        Data::Shared::Storage::check_readonly($recipe->{resolved}) if $self->{strict_readonly};
        $recipe->{storage_paths} = $recipe->{plan}{paths};
    }
    return $recipe;
}

sub _replay_manifest {
    my ($self) = @_;
    my $path = $self->manifest_path;
    my ($data, $raw) = Data::Shared::Manifest::read($path);
    local $self->{_replaying} = 1;
    local $self->{_opening} = 1;
    local $self->{_abs_cache} = {};     # shared with $check by the copy below
    my $check = bless { %$self, mounts => {} }, ref $self;
    my @recipes;
    for my $m (@{ $data->{mounts} }) {
        my $recipe = $self->_recipe($m->{name}, $m->{spec}, @{ $m->{args} });
        Carp::croak("Data::Shared: transient spec in manifest '$path'") if $recipe->{transient};
        Carp::croak("Data::Shared: duplicate mount '$recipe->{name}' in '$path'") if $check->{mounts}{$recipe->{name}};
        $check->_check_storage_paths($recipe->{name}, @{ $recipe->{storage_paths} });
        $check->{mounts}{$recipe->{name}} = { name => $recipe->{name}, storage_paths => $recipe->{storage_paths},
            composite => $recipe->{kind} eq 'composite' ? 1 : 0 };
        push @recipes, $recipe;
    }
    my $ok = eval { $self->_install_recipe($_) for @recipes; 1 };
    Carp::croak("Data::Shared: failed to replay manifest '$path': $@") unless $ok;
    $self->{_revision} = $data->{revision};
    $self->{_manifest_stamp} = $raw;
    $self->_invalidate_compiled;
    return 1;
}

sub _construct {
    my ($self, $resolved, $name, @args) = @_;
    my $plan = Data::Shared::Storage::plan($self, $resolved, $name, \@args);
    $self->_check_storage_paths($name, @{ $plan->{paths} });
    $self->_track_paths(@{ $plan->{paths} }) unless $self->{_opening};
    return Data::Shared::Storage::construct($self, $plan);
}

sub _install_recipe {
    my ($self, $recipe) = @_;
    my $name = $recipe->{name};
    Carp::croak("Data::Shared: mount '$name' already exists") if $self->{mounts}{$name};
    $self->_check_storage_paths($name, @{ $recipe->{storage_paths} });
    my ($handle, $file, $composite, $entry);
    if ($recipe->{kind} eq 'transient') {
        $handle = ref $recipe->{source} eq 'CODE' ? $recipe->{source}->($self, $name) : $recipe->{source};
        Carp::croak("mount '$name' factory did not return a handle") unless blessed($handle);
        $entry = Data::Shared::Registry::entry_for_class(ref $handle);
    } elsif ($recipe->{kind} eq 'composite') {
        $self->_track_paths($recipe->{dir}) unless $self->{_opening};
        $composite = Data::Shared::Composite->new(root => $self, name => $name,
            node => $recipe->{node}, dir => $recipe->{dir}, path => [split m{/}, $name],
            readonly => $self->{readonly}, strict_readonly => $self->{strict_readonly},
            pending_paths => $self->{_pending_paths},
            opening => $self->{_opening} || (defined $recipe->{dir} && -e $recipe->{dir}));
        $handle = $composite;
        $file = $recipe->{dir};
        $entry = $recipe->{resolved}{entry};
    } else {
        ($handle, $file) = $self->_construct($recipe->{resolved}, $name, @{ $recipe->{args} });
        $entry = $recipe->{resolved}{entry};
    }
    $entry ||= { key => ref($handle), dist => 'unknown', path_class => 'map', verbs => {} };
    $self->{mounts}{$name} = { name => $name, handle => $handle, entry => $entry,
        spec => $recipe->{spec}, args => $recipe->{manifest_args}, file => $file,
        transient => $recipe->{transient} ? 1 : 0, class => ref($handle), composite => $composite,
        storage_paths => $recipe->{storage_paths} };
    push @{ $self->{order} }, $name;
    $self->{_nested} = 1 if index($name, '/') >= 0;
    $self->{_changed} = 1;
    return $composite ? Data::Shared::Node->new($self, [split m{/}, $name]) : $handle;
}

sub mount {
    my ($self, $name, $spec, @args) = @_;
    _check_root($self);
    return $self->_mutate(sub { $self->_install_recipe($self->_recipe($name, $spec, @args)) });
}

sub unmount {
    my ($self, $name) = @_;
    return $self->_mutate(sub {
        return 0 unless delete $self->{mounts}{$name};
        @{ $self->{order} } = grep { $_ ne $name } @{ $self->{order} };
        $self->{_nested} = (grep { index($_, '/') >= 0 } keys %{ $self->{mounts} }) ? 1 : 0;
        $self->{_changed} = 1;
        return 1;
    });
}

sub handle {
    my ($self, $path) = @_;
    _check_root($self);
    return $self if !defined $path || $path eq '' || $path eq '/';
    my @components;
    if (ref $path eq 'ARRAY') { @components = @{ _check_components([ @$path ]) } }
    elsif (blessed($path) && $path->isa('Data::Shared::Compiled')) { @components = @{ $path->{components} } }
    else { @components = @{ _parse_string_path($path) } }
    return $self unless @components;
    if (!ref $path && $self->{mounts}{$path} && !$self->{mounts}{$path}{composite}) {
        return $self->{mounts}{$path}{handle};
    }
    my ($name, $mount, $rest) = _resolve($self, \@components);
    if (my $comp = $mount->{composite}) {
        return $comp->handle_at($self, $rest);
    }
    Carp::croak("Data::Shared: handle() path must name a mount exactly (got extra components)")
        if @$rest;
    return $mount->{handle};
}

sub _path_components {
    my ($self, $path) = @_;
    return [] if !defined $path;
    return [ @{ $path->{components} } ] if blessed($path) && $path->isa('Data::Shared::Node');
    return _check_components([ @$path ]) if ref $path eq 'ARRAY';
    return [ @{ $path->{components} } ] if blessed($path) && $path->isa('Data::Shared::Compiled');
    return _parse_string_path($path);
}

sub node {
    my ($self, $path) = @_;
    _check_root($self);
    return Data::Shared::Node->new($self, $self->_path_components($path));
}

sub children {
    my ($self, $path) = @_;
    _check_root($self);
    my @components = @{ $self->_path_components($path) };
    Carp::croak("Data::Shared: children() needs a composite path") unless @components;
    my ($name, $mount, $rest) = _resolve($self, \@components);
    Carp::croak("Data::Shared: mount '$name' is not composite") unless $mount->{composite};
    return $mount->{composite}->children_at($self, $rest);
}

sub shared_node { my ($r, @a) = @_; return $r->node(@a) }
sub shared_children { my ($r, @a) = @_; return $r->children(@a) }

# Through a named array, not `return sort ...`: sort in scalar context is
# undefined in perl, which made `if ($root->mounts)` false with mounts present.
sub mounts { my @k = sort keys %{ $_[0]{mounts} }; return @k }
sub mount_names { my @k = $_[0]->mounts; return @k }

sub mount_info {
    my ($self, $name) = @_;
    my $m = $self->{mounts}{$name} or return undef;
    return { name => $name, class => $m->{class}, key => $m->{entry}{key},
             dist => $m->{entry}{dist}, path_class => $m->{entry}{path_class},
             file => $m->{file}, transient => $m->{transient},
             composite => $m->{composite} ? 1 : 0 };
}

sub sync_all {
    my ($self) = @_;
    my $n = 0;
    for my $m (values %{ $self->{mounts} }) {
        if ($m->{handle}->can('sync')) { $m->{handle}->sync; $n++ }
    }
    return $n;
}

sub freeze_all {
    my ($self) = @_;
    Carp::croak("Data::Shared: cannot freeze a read-only root") if $self->{readonly};
    return Data::Shared::Manifest::with_lock($self, 0, sub {
        $self->_assert_revision;
        my $n = 0;
        # Insertion order, not hash order: a croak part-way through leaves the
        # store frozen in part, which opens in neither mode, and hash order
        # made which mounts were sealed differ from run to run.
        for my $name (@{ $self->{order} }) {
            my $h = $self->{mounts}{$name}{handle};
            next unless $h->can('freeze');
            # Already frozen is the goal state, not an error: without this a
            # second freeze_all, or one after any leaf was frozen directly,
            # croaked from the backend and could never succeed again.
            next if $h->can('frozen') && $h->frozen;
            # A composite seals its parent, its index and every child, and
            # reports how many; counting the mount instead under-reported it.
            if ($h->isa('Data::Shared::Composite')) { $n += $h->freeze }
            else { $h->freeze; $n++ }
        }
        return $n;
    });
}

sub frozen {
    my ($self) = @_;
    for my $name (@{ $self->{order} }) {
        my $mount = $self->{mounts}{$name};
        my $handle = $mount->{handle};
        if ($handle->can('frozen')) { return 0 unless $handle->frozen }
        # A build-then-load backend needs no sealing. Anything else that
        # cannot be sealed cannot be opened read-only either, so the
        # directory would not ship whatever freeze_all did.
        elsif (!($mount->{entry} && $mount->{entry}{immutable})) { return 0 }
    }
    return @{ $self->{order} } ? 1 : 0;
}

sub unlink_all {
    my ($self) = @_;
    Carp::croak("Data::Shared: root is read-only, cannot unlink") if $self->{readonly};
    return Data::Shared::Manifest::with_lock($self, 1, sub {
        # Already unlinked is the goal state, as it is for freeze_all and for a
        # composite destroy: a second call used to croak that the manifest
        # could not be read.
        my $published = !defined $self->{dir} || -e $self->manifest_path;
        return 0 unless $published || @{ $self->{order} };
        $self->_assert_revision if $published;
        my $n = 0;
        # Insertion order, not hash order: the last iteration over mounts that
        # left a partial failure's surviving set up to the hash seed.
        for my $name (@{ $self->{order} }) {
            my $handle = $self->{mounts}{$name}{handle};
            if ($handle->can('unlink')) { $handle->unlink; $n++ }
        }
        if ($published && defined $self->{dir}) {
            if (CORE::unlink($self->manifest_path)) { $n++ }
            # Counting it regardless credited a manifest this call did not
            # remove.
            elsif (!$!{ENOENT}) { Carp::croak("Data::Shared: cannot unlink manifest: $!") }
        }
        # Ours and empty once every composite is gone. The lock file stays: a
        # process still holding it would keep an fd to a deleted file while the
        # next one created a fresh lock, and the two would not serialise.
        rmdir "$self->{dir}/.children" if defined $self->{dir};
        $self->{mounts} = {};
        $self->{order} = [];
        $self->{_nested} = 0;
        $self->_invalidate_compiled;
        return $n;
    });
}

sub stats {
    my ($self) = @_;
    my %out;
    for my $name ($self->mounts) {
        my $h = $self->{mounts}{$name}{handle};
        $out{$name} = $h->can('stats') ? $h->stats : { class => ref $h };
    }
    return \%out;
}

sub get    { my ($s, @a) = @_; return shared_get($s, @a) }
sub set    { my ($s, @a) = @_; return shared_set($s, @a) }
sub delete { my ($s, @a) = @_; return shared_delete($s, @a) }
sub exists { my ($s, @a) = @_; return shared_exists($s, @a) }
sub incr   { my ($s, @a) = @_; return shared_incr($s, @a) }
sub call   { my ($s, @a) = @_; return shared_call($s, @a) }
sub push   { my ($s, @a) = @_; return shared_push($s, @a) }
sub pop    { my ($s, @a) = @_; return shared_pop($s, @a) }
sub compile { my ($s, @a) = @_; return shared_compile(@a) }

1;

__END__

=encoding utf8

=head1 NAME

Data::Shared - Path-addressed facade over the Data-*-Shared family

=head1 SYNOPSIS

    use Data::Shared qw(shared_get shared_set shared_exists shared_call
                        shared_push shared_pop shared_compile sharedc_get);

    my $root = Data::Shared->new;
    $root->mount('cache', 'hashmap:ii', undef, 100_000);
    $root->mount('visitors', 'hyperloglog', undef, 14);
    $root->mount('jobs', 'queue:int', undef, 1024);

    shared_set($root, '/cache/42', 100);
    shared_get($root, '/cache/42');            # 100
    shared_exists($root, '/cache/42');         # 1

    shared_call($root, '/visitors', 'add', 'alice');
    shared_call($root, '/visitors', 'count');  # ~1

    shared_push($root, '/jobs', 42);
    shared_pop($root, '/jobs');                # 42

    my $app = Data::Shared->new('/tmp/app.shared');
    $app->mount('cache', 'hashmap:ii', undef, 100_000);
    my $same = Data::Shared->open('/tmp/app.shared');
    shared_get($same, '/cache/42');

    my $cp = shared_compile('/cache/42');
    sharedc_get($root, $cp);

    use Data::Shared qw(shareda_get shareda_set);
    $root->mount('names', 'hashmap:ss', undef, 100_000);
    shareda_set($root, ['names', 'a/b'], 1);   # a component may contain '/'
    shareda_get($root, ['names', 'a/b']);

=head1 DESCRIPTION

Data::Shared wraps all 39 C<Data-*-Shared> distributions behind one
path-based API inspired by L<Data::Path::XS>. A root object holds named
mounts; a slash path resolves to a mount plus an intra-structure
operation:

    /cache/42        mount "cache", key 42
    /lat/0/5         mount "lat", indices 0, 5 (NDArray)
    /visitors        mount "visitors" (used with shared_call)

This is a deliberate departure from L<Data::Path::XS>: there is nothing
to walk inside an opaque shared-memory handle, so a plain mount
resolves in two levels (mount resolution, then adapter dispatch)
rather than by walking nested hashes and arrays; composite mounts
(L</DEEP PATHS (COMPOSITES)>) walk one child address per level. The
three API tiers (string, array, compiled) and their syntax otherwise
mirror L<Data::Path::XS>.

The facade is pure Perl. All hot operations still execute in the
underlying XS of each leaf. The keyword syntax of L<Data::Path::XS>
(C<pathget>/C<pathset>) is not provided; requesting C<:keywords>
croaks (see L</PERFORMANCE> for why dispatch stays in Perl).

B<Linux only, 64-bit Perl>, matching every leaf. Handles are never
cloned into ithreads (C<CLONE_SKIP>).

The leaf dists are recommended rather than required, so installing this
facade does not compile all 39 of them. Install the ones you mount;
mounting a type whose dist is absent croaks naming the dist to install.
C<cpanm --with-recommends Data::Shared> installs every leaf.

=head1 ROOT AND MOUNTS

=head2 Data::Shared->new([$dir])

Without a directory, creates an anonymous root. With a directory,
creates it if needed; if a F<manifest.json> already exists there it is
replayed (every mount reopened), otherwise an empty manifest is
written. When the root is file-backed and a mount's constructor
arguments are empty, start with C<undef>, or start with C<':file'>, the
facade supplies C<$dir/E<lt>nameE<gt>.shm> as the backing file.

=head2 Data::Shared->open($dir)

Requires an existing directory and manifest. The complete manifest schema,
mount specs, and mount backing paths are checked before constructing handles.
Missing storage is an error; opening never recreates an empty backing file.
Composite descendant files are checked when the child is opened lazily.
Native backends validate their own file headers.

=head2 Data::Shared->open_readonly($dir, strict => 1)

Replays the manifest opening each leaf with C<new_readonly> where the
leaf supports it. Generic mutating verbs (C<set>, C<delete>, C<incr>,
C<push>, C<pop>) and root lifecycle writes (C<mount>, C<unmount>,
C<unlink_all>) croak on a read-only root. For leaves without
C<new_readonly>, the facade falls back to the normal constructor;
native methods reached via C<shared_call> or C<handle> retain that
leaf's own permissions. The root flag alone does not enforce
read-only access through native methods.

With C<strict =E<gt> 1>, every backend in the declared tree must provide
C<new_readonly> or be immutable (PerfectHash). Unsupported leaves are
rejected before opening handles, including lazy composite leaves. The
producer must freeze backends that require frozen files. Without C<strict>,
the compatibility fallback described above remains available. Strict mode
enforces native data-write guards; raw handles still expose their backend
API and direct filesystem operations remain subject to filesystem permissions.
Native C<unlink>, C<destroy>, and C<freeze> calls through the facade are
blocked on every read-only root.

=head2 $root->mount($name, $spec, @ctor_args)

Mounts a structure under C<$name> (which may itself contain C</>, for
nested namespaces; longest-prefix wins). C<$spec> may be:

=over 4

=item * a short spec: C<'hashmap'>, C<'hashmap:ii'>, C<'buffer:i64'>,
C<'queue:int'>, C<'sync:semaphore'>, C<'sortedset:strings'>, etc.
Short specs are all-lowercase (mixed case is accepted and resolves
to the lowercase canonical form). See L<Data::Shared::Registry> for
the full inventory.

=item * a full class name: C<'Data::HashMap::Shared::SS'>.

=item * a hashref: C<< { spec => 'hashmap:ss', args => [...] } >> or
with an explicit C<ctor> (for C<new_weighted>/C<new_decayed> style
constructors, also available as C<'reservoir:weighted'> /
C<'topk:decayed'>).

=item * an already-constructed handle (transient; not written to the
manifest).

=item * a coderef factory called as C<$factory-E<gt>($root, $name)>
(transient).

=item * a composite spec (arrayref or hashref with C<child>): see
L</DEEP PATHS (COMPOSITES)>.

=back

Returns the native handle (for a composite mount, a
L<Data::Shared::Node> for the mount). C<$root-E<gt>handle($path)>
also returns it, and any native method can always be reached that
way or via C<shared_call>.

Configuration arrays and hashes are copied before construction. Cycles are
rejected; constructor arguments that cannot be serialized make the mount
transient. Failed mount publication restores the previous namespace and
removes backing paths created by that attempt. Existing files are retained.
Factories manage their own external side effects. Nested mount mutations
inside a factory are rejected.

Special cases: C<perfecthash> mounts need a built file path, a
C<< { build_int => \@keys, path => $file } >> /
C<build_str> hashref, a factory, or a loaded handle (it is an
immutable build-then-load structure). A build spec creates a missing file
once; an existing file is loaded without rebuilding. C<sortedset:strings> takes
C<< mount('names', 'sortedset:strings', { max => 100_000 }) >>;
C<set>/C<keys> backing paths are auto-filled for file-backed roots.
Backing paths already owned by another mount are rejected before
construction, including aliases produced by filename sanitization
(e.g. C<a/b> and C<a__b>) and string SortedSet sidecars. Mount the
same native handle under another name to share it intentionally.

=head2 $root->unmount($name), $root->mounts, $root->mount_info($name)

Lifecycle and introspection for mounts.
Manifest changes use a directory lock and revision. A root opened before
another writer's topology change receives a C<stale manifest revision> error
before constructors or factories run. Reopen the root and retry with the
current configuration. Roots keep their own mount namespace until reopened;
they do not refresh automatically. C<freeze_all> and C<unlink_all> also check
the revision before operating on shared storage.

A mount argument has to be representable in the manifest, since replaying it
is how every later process reopens the store: C<Inf>, C<NaN> and a lone
surrogate are refused at mount time rather than published as text nothing can
parse back. Strings are recorded as bytes, so a backing path keeps naming its
file whether you pass it as bytes or as characters.

Version-one manifests without a revision are accepted as revision zero.
New writers add a revision and a F<.manifest.lock> file; existing backend
file formats and generated filenames are preserved. Concurrent writers must
all use the revised protocol. Mount topology is simplest to manage from one
coordinator.

=head2 $root->sync_all, $root->freeze_all, $root->unlink_all, $root->stats, $root->frozen

Proxies applied to every mount whose handle supports the method, in
mount order. C<stats> returns a hashref of per-mount stats (or class
name where a leaf has no C<stats>). A composite mount counts as its
whole subtree: parent, child index and every registered child, open or
not. C<freeze_all> returns the number of handles it sealed, so 0 is a
success: either everything was already sealed, or no mount can be.
C<frozen> tells those apart, and is what a producer should assert
before shipping the directory. A mounted native handle is sealed with
the rest, so the caller's own object becomes read-only. C<unlink_all>
removes the mounts and the manifest but leaves F<.manifest.lock>, which
another process may still be holding, so the directory is not empty
afterwards.

=head1 PATH FORMAT

Components are separated by C</>. A leading C</> is optional,
repeated and trailing slashes are tolerated, and the empty path
addresses the root (C<shared_get> returns the root, C<shared_exists>
is true, mutating the root croaks) -- all mirroring
L<Data::Path::XS>. The first component(s) select the mount (longest
prefix match); the remainder is interpreted by the mount's adapter:

=over 4

=item * Map-like (HashMap, Buffer, RadixTree, Intern, Pool,
PerfectHash): one key/index component. RadixTree instead joins the
remainder with C</> so route-style keys work in string paths.

=item * Set-like (Bloom family, BitSet, RoaringBitmap, SortedSet,
DisjointSet): one member component.

Map- and set-like mounts croak on a longer path rather than using the
first component and discarding the rest, which addressed a record the
path did not name. RadixTree, which joins, is unaffected.

=item * Indexed (NDArray, Fenwick, Fenwick2D, SegmentTree, Graph):
all remaining components are indices/coordinates.

=item * Queue-, sketch- and sync-like: normally no remainder; use
C<shared_push>/C<shared_pop>/C<shared_call>.

=back

No escaping is provided in the string tier: keys containing C</> or
the empty string need the array tier.

=head1 GENERIC VERBS

C<shared_get>, C<shared_set>, C<shared_delete>, C<shared_exists> and
C<shared_incr> are honest sugar over native methods, defined per type
in L<Data::Shared::Registry> (e.g. HashMap C<put/get/remove/exists>,
RadixTree C<insert/lookup/delete/exists>, SortedSet C<add/score/remove>,
Intern C<intern/id_of>). Where a verb would lie (a plain Bloom filter
has no delete; sketches and sync primitives have no keyed get/set) it
croaks with guidance to use C<shared_call> instead of faking it.

C<shared_exists> always returns C<1> or C<0>. C<shared_incr> uses
C<incr_by> when a delta is given and the leaf supports it; a leaf with
neither C<incr_by> nor a delta form of C<incr> (most C<buffer> variants)
rejects the delta from its own XS, so use C<shared_call> there.

A few per-backend behaviours are the leaf's, not the facade's, and are
worth knowing before you rely on them. C<shared_set($path, 0)> clears for
BitSet but counts as an add for RoaringBitmap and the Cuckoo and counting
Bloom filters, whose value argument is ignored; use C<shared_delete> to
remove. C<shared_delete> on a C<buffer> writes the variant's zero, which
for C<buffer:str> is the one-character string C<"0">. A write can also
fail by returning false rather than croaking: C<sortedset:strings> and
C<intern> derive a string arena of 32 bytes per declared entry, so longer
members exhaust it early and C<shared_set> then returns C<undef>. Pass a
larger C<arena> (C<sortedset:strings>) or third constructor argument
(C<intern>) if your members are long, and check the return value. Keys cross into XS
as bytes, so encode wide characters first: a character above U+00FF is
accepted by the HashMap and SortedSet families and fatal in RadixTree,
Intern and the filter family. An integer-addressed leaf numifies a
non-integer key, so C<'abc'> addresses element 0: C<buffer>, C<fenwick>,
C<segmenttree> and C<disjointset> refuse it, but C<bitset>,
C<roaringbitmap>, C<pool>, C<ndarray>, C<graph>, C<fenwick2d>,
C<ringbuffer>'s C<get> and the integer C<hashmap> variants read or write
element 0 (with a warning under C<-w>).

=head2 shared_call($root, $path, $method, @args)

The escape hatch that guarantees full coverage: resolves C<$path> to
a mount, prepends any remaining path components to C<@args>, and calls
the native C<$method>. Every native operation of every leaf is
reachable this way, including those with no generic verb. On a
composite mount the first remaining component instead selects the
child, and the rest are passed to the child's method.

    shared_call($root, '/visitors', 'add_many', ['a', 'b']);
    shared_call($root, '/fenwick', 'prefix', 500);
    shared_call($root, '/sem', 'acquire', 1.5);

=head2 shared_push($root, $path, @values) / shared_pop($root, $path, @args)

Queue sugar mapping to the native pair per type (Queue C<push/pop>,
Deque C<push_back/pop_front>, Heap C<push/pop> with priority+value,
Log C<append> (no pop), PubSub C<publish> (no pop), RingBuffer
C<write> (no pop)). Unsupported directions croak.

=head1 ARRAY PATH API

C<shareda_get/set/delete/exists/incr/call/push/pop> take an arrayref
of components instead of a slash string. Binary-safe; components may
contain C</> or be empty strings. Mount resolution uses the same
longest-prefix rule over components.

=head1 COMPILED PATH API

C<shared_compile($path)> (string or arrayref) returns a
L<Data::Shared::Compiled> object holding parsed components;
C<sharedc_*> functions reuse it without re-parsing, mirroring
C<path_compile>/C<pathc_*> in L<Data::Path::XS>. On first use against
a root the compiled path also caches the resolved mount, verb and
key, so later calls go straight to the native method; the cache is
invalidated automatically when mounts change. Compiled objects are
still per-process: recompile after C<fork> if the child mounts
differently.

=head1 DEEP PATHS (COMPOSITES)

A composite mount nests structures: the parent gives each child a
stable address, and the facade keeps one child instance per address
(no leaf can physically contain another). Specs are nested
arrayrefs (constructor arguments exclude the backing path, which the
facade supplies per child; a leading C<undef> placeholder is
tolerated) or hashrefs with C<spec>/C<args>/C<child>. In the
arrayref form a trailing arrayref is always the child spec, so a
leaf whose constructor takes a trailing arrayref argument (such as
SpatialHash grid wrapping) must use the hashref form:

    $root->mount('users', ['hashmap:ss', 100_000, ['bloomfilter', 10_000, 0.01]]);
    $root->mount('leaders', ['sortedset:strings', { max => 100_000 }, ['bloomfilter', 10_000, 0.01]]);
    $root->mount('atlas', ['hashmap:ss', 100_000, ['kdtree', 2, 100_000, ['hashmap:ss', 10_000]]]);

    shared_set($root, '/users/alice/event-42', 1);
    shared_exists($root, '/users/alice/event-42');
    shared_set($root, '/leaders/alice', 1500);           # SortedSet score
    shared_get($root, '/atlas/europe/42/name');

Parents must be addressable: C<hashmap> and C<sortedset> (child per
key/member; for SortedSet the path ending at the child still reads
and writes its score), plus C<kdtree> and C<graph> as id-parents
(child per point/node id; geometry is added through
C<< $root->node('/atlas/europe')->call('add', [$x, $y], $id) >>, and
a deep write for an id does not require the point to exist).
Bloom filters, sketches, queues, stacks, logs, sync and timing
mounts cannot be parents (probabilistic or transient: their members
cannot be enumerated or stably addressed) and are rejected at mount
time; use them as child leaves.

Semantics at an intermediate path: C<shared_get> returns a
L<Data::Shared::Node> (for SortedSet, the score instead),
C<shared_exists> reports whether a child is registered,
C<shared_delete> deletes the whole subtree, and C<shared_set>
croaks except for the SortedSet score case. C<< $root->node($path) >>
(also exported as C<shared_node>) returns a cursor with relative-path
C<get/set/delete/exists/incr/push/pop/call/call_at/node/children/handle>
methods; C<< $root->children($path) >> (C<shared_children>) lists
registered child addresses. C<handle> on a child leaf path returns
its native handle. Reads of a missing child never create one;
writes create it lazily, and so does any C<call> there, since the
method may mutate. Probe with C<shared_exists>, not a read-only
call, or a loop over candidate addresses will register every one of
them and exhaust the child budget.

Each composite declares C<max_children> (default 10_000) and
C<cache_size> open children (default 32, LRU close/reopen) via the
hashref spec form or a trailing C<{max_children =E<gt> ..., cache_size =E<gt> ...}>
in the arrayref form. One child instance is one backing segment, so
high-cardinality parents need an explicit budget. Anonymous composites
retain all opened children until subtree deletion or root destruction,
because an anonymous segment cannot be reopened after eviction;
C<cache_size> bounds only file-backed child caches. Use a file-backed
root when processes need to discover children created after C<fork>.
File-backed roots
store children under F<.children/> next to the manifest and reopen
them on replay; composite mounts support C<sync_all>, C<stats>
(with child counts), C<freeze_all>, and subtree deletion. Compiled
paths over composites stay correct across child creation, eviction,
and deletion because they re-dispatch to the child per call.

Allocation, construction, publication, score-only registration, and subtree
deletion use the composite lifecycle lock. Failed construction rolls back
new registrations, counts, and newly created paths; existing scores and
reservations are preserved. Allocated child IDs are never reused. Cached
leaf operations use the backend's own locking. An operation already in
progress during deletion may complete against the old instance; an explicit
native handle continues to refer to that instance after recreation.

The shared child counter is maintained under the lifecycle lock, and is
rebuilt only when an unfinished mutation marker is found: on opening a
writable composite, or when a lifecycle lock encounters one. A holder
that dies mid-section releases the lock either way: the kernel releases
a file-backed composite's file lock, and an anonymous composite's lock
is recovered from the dead owner, at the cost of about 8 kB of mapping
per anonymous composite instance. Unpublished directories may remain and
are retained for explicit recovery: each holds its child's storage, no
API reports them, and only C<unlink_all> reclaims them, so a long-running
producer that is killed repeatedly accumulates them until the store is
torn down. A preexisting unpublished directory for
a reserved child is reported as an error. This provides exception rollback
and limited interruption recovery, without promising power-loss transactions
or automatic orphan cleanup.

New readiness markers include the child ID; legacy readiness flags remain
readable. Counters and interruption markers use additional registry keys.
Old undersized registries need adequate capacity before further writes;
missing construction records are not reconstructed automatically.

=head1 PERFORMANCE

The facade is pure Perl; every operation ends in the leaf's XS, so
per-call overhead depends on the tier. A sample run of
F<bench/overhead.pl> on one idle x86_64 host, reading one integer key:

    native handle    0.08 us/op
    compiled         0.58 us/op
    array path       2.07 us/op
    shared_call      2.21 us/op
    string path      2.80 us/op

The string and array tiers pay for path parsing and mount resolution on
every call. A compiled path skips both: a live binding is checked only
for root identity and generation, and the remaining arguments reach the
bound closure without being copied again. Use compiled paths, or the
native handle from C<handle>, in hot loops. The handle is the floor and
costs no facade call at all, which is why dispatch is not in XS: an XS
dispatcher would speed up a middle tier that callers can bypass. Run
F<bench/benchmark.pl> and F<bench/overhead.pl> on your hardware.
F<bench/composite.pl> measures deep reads with a warm child cache
and with repeated cache eviction. Composite compiled paths still
resolve the child registry on every call; their cost differs from
flat compiled paths.

Creating flat mounts costs quadratic total time in their number: each one
validates and republishes the whole manifest, so the marginal cost of one
more doubles as the count doubles. On one idle host the average was about
1.3 ms per mount at 25 mounts and 7.6 ms at 200, i.e. 1.5 s to create 200,
with the 200th alone costing about 15 ms. Keys are not affected: writing
10_000 keys into one flat mount took 32 ms and never touches the manifest.
Opening such a root is superlinear too, and paid by every process that opens
it: about 0.13 s to replay 400 mounts on the same host.
A namespace with hundreds of B<mounts> belongs in a composite mount
(L</DEEP PATHS (COMPOSITES)>) instead, where children are registered in the
parent and the root manifest stays a single record.

F<bench/scaling.pl> records child-creation scaling, working-set cache costs,
process RSS, and wall-time latency percentiles for concurrent increments.
Its samples are workload measurements, not latency guarantees. Child counts
and file-cache LRU updates now take constant time during normal operation.
Bound compiled dispatch is owned by the root, so retaining a compiled path
does not retain an unmounted native handle. Backend minimum versions are
the validated baselines recorded in L<Data::Shared::Registry>; they are
published as the recommended minima and enforced at first backend use.
Nothing checks them at installation, because the leaves are not required.

=head1 CLASSIFICATION OF THE 39 LEAVES

Map-like: HashMap (10 variants), Buffer (11), RadixTree, Intern,
Pool (+I64/I32/F64/Str), PerfectHash (read-only).
Set-like: BloomFilter, CountingBloomFilter, CuckooFilter, BitSet,
RoaringBitmap, SortedSet (+Strings), DisjointSet.
Queue-like: Queue, Deque, Stack, Heap, RingBuffer, Log, PubSub.
Indexed: NDArray, Fenwick, Fenwick2D, SegmentTree, KDTree,
IntervalTree, SpatialHash, Graph.
Sketch/stats: HyperLogLog, CountMinSketch, MinHash, TopK, DDSketch,
Histogram, Reservoir.
Sync/timing (call-only): Sync (Semaphore, Barrier, RWLock, Condvar,
Once), TimingWheel, HierTimingWheel, ReqRep.

=head1 SECURITY

A file-backed root is created mode C<0700>, and the manifest and the
C<.manifest.lock> that serialises topology changes are created C<0600>.
Backing files come from the leaves, which create them C<0600> with
C<O_NOFOLLOW> and C<O_EXCL>. A directory or lock that already exists keeps
its own mode, so sharing a root between users stays an explicit choice; the
facade does not offer a mode argument for it, and a group-writable root lets
any member of that group unlink the manifest.

The manifest is trusted input. Whatever can write it chooses which mounts
this process opens and which backing files it maps, so a writer who also
controls those files controls what the process attaches to: a recorded
argument list is not re-applied to a file that already exists, and the leaf
rejects a file whose header does not match the declared type, but the file
itself decides the mapping. An C<args> entry naming an absolute path is
honoured, so a manifest can reach a file outside the root.

Mount names are sanitised into the root directory, so a name containing
C<..> or C</> cannot place a backing file outside it, and a manifest naming
a backing file that is absent is refused rather than silently recreated.
Anything you grant write access to a shared mapping is trusted not to
corrupt it while others are attached, as with the leaves.

=head1 SEE ALSO

L<Data::Path::XS> (the API model), L<Data::Shared::Registry> (the
inventory and verb tables), L<Data::Shared::Cookbook> (per-dist
recipes), and each C<Data::*::Shared> leaf for its native semantics.

=head1 AUTHOR

vividsnow

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
