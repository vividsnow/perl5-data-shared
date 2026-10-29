package Data::Shared;
use strict;
use warnings;

our $VERSION = '0.01';

# Report mount-time errors at the caller across the manifest lock.
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
    $p =~ s{^/+}{};   # /+, or "//a/b" keeps an empty leading component
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

# Resolve overloaded components now so compiled paths retain a stable spelling.
# Callers pass a fresh array, so replacing a component in place is safe.
sub _check_components {
    my ($components) = @_;
    for my $c (@$components) {
        next if defined $c && !ref $c;
        my $stringify = defined $c && overload::Method($c, '""');
        Carp::croak("path component must be a defined string") unless $stringify;
        my $string = $stringify->($c, undef, '');
        # Bound overload chains explicitly; interpolation can hide undef or self-return.
        for (my $depth = 0; ref $string; $depth++) {
            my $inner = overload::Method($string, '""') or last;
            Carp::croak("path component must be a defined string") if $depth >= 16;
            $string = $inner->($string, undef, '');
        }
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
    my ($record, $rest, $method, @args) = @_;
    my $handle = $record->{handle};
    my $label = defined $record->{name} ? "mount '$record->{name}'" : 'handle';
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
    my (undef, $mount, $rest) = _resolve($root, $components);
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
    my (undef, $mount, $rest) = _resolve($root, $components);
    if (my $comp = $mount->{composite}) {
        return $comp->dispatch_pushpop($root, $which, $rest, @args);
    }
    return _dispatch_record_pushpop($which, $mount, $rest, @args);
}

sub _dispatch_call {
    my ($root, $components, $method, @args) = @_;
    _check_root($root);
    Carp::croak("Data::Shared: a call requires a method name")
        unless defined $method && length $method;
    _check_native_call($root, $method);
    Carp::croak("Data::Shared: a call path must name a mount") unless @$components;
    my ($name, $mount, $rest) = _resolve($root, $components);
    # Remove the manifest entry before retiring its backing storage.
    if ($method eq 'unlink' || $method eq 'destroy') {
        return $root->unmount($name, unlink => 1) unless @$rest;
        # Leaf unlink/destroy ignore record suffixes and remove the whole file.
        Carp::croak("Data::Shared: '$method' retires a mount or a composite child,"
            . " not the record at '/" . join('/', @$components) . "';"
            . " use shared_delete to remove a record")
            unless $mount->{composite};
    }
    if (my $comp = $mount->{composite}) {
        return $comp->dispatch_call($root, $rest, $method, @args);
    }
    return _dispatch_record_call($mount, $rest, $method, @args);
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
    # Cached closures are weak references and may have expired.
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

# A live binding requires the same root identity and generation.
# Mutating callers must check readonly before taking this shortcut.
sub _bound_hit {
    my ($root, $cp, $key) = @_;
    return undef unless ref $root && ref $cp eq 'Data::Shared::Compiled';
    my $hit = $cp->{_bc} && $cp->{_bc}{$key} or return undef;
    # [3] is weakened; test it survived rather than handing back dead code.
    return undef unless $hit->[3] && $hit->[3] == $root && $hit->[1] == ($root->{gen} || 0);
    return $hit->[2];
}

# Bare &name and &$ref calls alias the caller's @_; never modify it here.
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
    Carp::croak("Data::Shared: a call requires a method name") unless defined $m && length $m;
    _check_native_call($r, $m);
    if (($m eq 'unlink' || $m eq 'destroy') && @{ $cp->{components} }) {
        my ($name, $mount, $rest) = _resolve($r, $cp->{components});
        return $r->unmount($name, unlink => 1) unless @$rest;
        Carp::croak("Data::Shared: '$m' retires a mount or a composite child,"
            . " not the record at '/" . join('/', @{ $cp->{components} }) . "';"
            . " use shared_delete to remove a record")
            unless $mount->{composite};
    }
    my $bound = _compiled_code($r, $cp, 'call', $m);
    return $bound->(@a);
}

sub registry { return Data::Shared::Registry::registry() }
sub available_types { return Data::Shared::Registry::keys_list() }

sub _empty_root {
    my ($class, $dir, %opt) = @_;
    return bless { dir => $dir, mounts => {}, order => [], readonly => $opt{readonly} ? 1 : 0,
        strict_readonly => $opt{strict} ? 1 : 0, gen => 0, _nested => 0,
        _frozen_ok => $opt{frozen_ok} ? 1 : 0,
        _revision => 0, _compiled => {}, _retained => [] }, $class;
}

sub new {
    my ($class, $dir) = @_;
    my $self = _empty_root($class, $dir);
    if (defined $dir) {
        require File::Path;
        # Preserve existing directory modes; sharing a root is an administrator choice.
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

# Attach sealed leaves read-only while allowing lifecycle cleanup.
sub open_sealed { my ($class, $dir) = @_; return _open_root($class, $dir, frozen_ok => 1) }

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
        # Variant module names do not determine the distribution that provides them.
        $e =~ s/ \(\@INC.*//s;
        $e =~ s/\s+\z//;
        my $how = defined $dist
            ? "install the $dist dist"
            : "install the dist providing $cls";
        Carp::croak("Data::Shared: backend $cls is not available; $how: $e");
    }
    return 1;
}

sub _storage_name {
    my ($name) = @_;
    $name =~ s{/}{__}g;
    $name =~ s{[^A-Za-z0-9_.-]}{_}g;
    return $name;
}

sub _file_for {
    my ($self, $name) = @_;
    return "$self->{dir}/" . _storage_name($name) . '.shm';
}

sub _check_storage_paths {
    my ($self, $name, @paths) = @_;
    return unless keys %{ $self->{mounts} };
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

# Cache paths for one manifest operation; symlinks may change between operations.
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

# Lock order: topology, then composites from parent to child.
# Workers may finish opening old children before their directories are removed.
sub _lock_composite_dirs {
    my ($paths) = @_;
    my @held;
    require Fcntl;
    # Discover each level under its parent's lock; children may be created lazily.
    my @queue = @$paths;
    while (my $path = shift @queue) {
        next unless -d $path && !-l $path;
        my $lockfile = "$path/.lock";
        my $fh;
        if (-e $lockfile) {
            # Linux permits exclusive flock on a read-only descriptor; missing locks need no wait.
            # Never proceed without the lock: only ENOENT may be skipped.
            unless (CORE::open($fh, '+<', $lockfile)
                    || CORE::open($fh, '<', $lockfile)) {
                Carp::croak("Data::Shared: cannot open composite lock '$lockfile': $!")
                    unless $!{ENOENT};
            }
        }
        if ($fh) {
            until (flock $fh, Fcntl::LOCK_EX()) {
                next if $!{EINTR};
                Carp::croak("Data::Shared: cannot lock composite '$lockfile': $!");
            }
            push @held, $fh;
        }
        opendir my $dh, $path or next;
        push @queue, map { "$path/$_" } grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
    }
    return \@held;
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
    my $data = { version => 1, revision => $self->{_revision}, mounts => \@mounts };
    # Omit an empty ledger to preserve manifests from stores that never retained storage.
    $data->{retained} = [ @{ $self->{_retained} } ] if @{ $self->{_retained} };
    return $data;
}

sub _write_manifest {
    my ($self) = @_;
    return unless defined $self->{dir};
    Carp::croak('Data::Shared: root is read-only, cannot write manifest') if $self->{readonly};
    my $data = $self->_manifest_data;
    $self->{_manifest_stamp} = Data::Shared::Manifest::write($self->manifest_path, $data);
    $self->_stamp_manifest_identity;
    return 1;
}

# Rebuilds can reproduce revisions and bytes; the manifest inode distinguishes them.
sub _stamp_manifest_identity {
    my ($self) = @_;
    @{$self}{qw(_manifest_dev _manifest_ino)} = (stat $self->manifest_path)[0, 1];
    return;
}

sub _assert_revision {
    my ($self) = @_;
    return unless defined $self->{dir};
    Carp::croak('Data::Shared: this store was unlinked; create or open a root again')
        if defined $self->{_manifest_stamp} && !-e $self->manifest_path;
    my ($current, $stamp) = Data::Shared::Manifest::read($self->manifest_path);
    Carp::croak('Data::Shared: stale manifest revision; reopen the root before changing mounts')
        unless $current->{revision} == $self->{_revision} && $stamp eq $self->{_manifest_stamp};
    my ($dev, $ino) = (stat $self->manifest_path)[0, 1];
    Carp::croak('Data::Shared: this store was replaced; open the root again')
        if defined $self->{_manifest_ino} && defined $ino
        && ($dev != $self->{_manifest_dev} || $ino != $self->{_manifest_ino});
}

sub _invalidate_compiled {
    my ($self) = @_;
    $self->{gen}++;
    $self->{_compiled} = {};
}

sub _mutate {
    my ($self, $code, $after) = @_;
    Carp::croak('Data::Shared: root is read-only, cannot change mounts') if $self->{readonly};
    Carp::croak('Data::Shared: nested mount mutations are not supported') if $self->{_mutating};
    return Data::Shared::Manifest::with_lock($self, 1, sub {
        $self->_assert_revision;
        local $self->{_mutating} = 1;
        local $self->{_pending_paths} = [];
        local $self->{_abs_cache} = {};
        local $self->{_changed} = 0;
        # Transient changes invalidate local bindings without publishing a new revision.
        local $self->{_published} = 0;
        my ($mounts, $order, $nested, $revision, $stamp, $retained, $dev, $ino) =
            ({ %{ $self->{mounts} } }, [ @{ $self->{order} } ], $self->{_nested}, $self->{_revision},
             $self->{_manifest_stamp}, [ @{ $self->{_retained} } ],
             $self->{_manifest_dev}, $self->{_manifest_ino});
        my $ret;
        my $ok = eval {
            $ret = $code->();
            if ($self->{_published}) {
                $self->{_revision}++;
                $self->_write_manifest;
            }
            1;
        };
        my $err = $@;
        if (!$ok) {
            @{$self}{qw(mounts order _nested _revision _manifest_stamp _retained
                        _manifest_dev _manifest_ino)} =
                ($mounts, $order, $nested, $revision, $stamp, $retained, $dev, $ino);
            my $cleanup = _cleanup_paths($self->{_pending_paths});
            # Preserve exception objects across rollback.
            die $err if ref $err;
            # Strip only the final Carp location; messages may contain their own " at ...".
            $err =~ s/\A(.*[^\s])\s*\bat .+ line \d+\.?\s*\z/$1/s;
            Carp::croak($err . (length $cleanup ? " (rollback: $cleanup)" : ''));
        }
        $self->_invalidate_compiled if $self->{_changed};
        # Retire storage under the topology lock, after publishing its removal.
        $after->() if $after;
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
    my $recipe = { name => $name, spec => $spec, manifest_args => $args,
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
                my $safe = _storage_name($name);
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
        my $plan = Data::Shared::Storage::plan($self, $recipe->{resolved}, $name, $recipe->{args});
        Data::Shared::Storage::require_files($plan) if $self->{_opening};
        Data::Shared::Storage::check_readonly($recipe->{resolved}, $name) if $self->{strict_readonly};
        $recipe->{storage_paths} = $plan->{paths};
    }
    return $recipe;
}

sub _replay_manifest {
    my ($self) = @_;
    my $path = $self->manifest_path;
    my ($data, $raw) = Data::Shared::Manifest::read($path);
    local $self->{_opening} = 1;
    local $self->{_abs_cache} = {};     # shared with $check by the copy below
    # Load retained paths before replay so adopted storage can leave the ledger.
    $self->{_retained} = [ @{ $data->{retained} || [] } ];
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
    unless ($ok) {
        my $why = $@;
        $why =~ s/\A(.*[^\s])\s*\bat .+ line \d+\.?\s*\z/$1/s unless ref $why;
        Carp::croak("Data::Shared: failed to replay manifest '$path': $why");
    }
    $self->{_revision} = $data->{revision};
    $self->{_manifest_stamp} = $raw;
    $self->_stamp_manifest_identity;
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
            pending_paths => $self->{_pending_paths}, frozen_ok => $self->{_frozen_ok},
            # Adoption must validate the chosen spec; replay tolerates legacy specs.
            replaying => $self->{_opening} ? 1 : 0,
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
    $self->{_published} = 1 unless $recipe->{transient};
    # Adopted paths must leave the retained-storage ledger.
    if (@{ $self->{_retained} } && @{ $recipe->{storage_paths} }) {
        my %adopted = map { $_ => 1 } map { $self->_ledger_form($_) } @{ $recipe->{storage_paths} };
        my $before = @{ $self->{_retained} };
        @{ $self->{_retained} } = grep { !$adopted{$_} } @{ $self->{_retained} };
        $self->{_published} = 1 if @{ $self->{_retained} } != $before;
    }
    return $composite ? Data::Shared::Node->new($self, [split m{/}, $name]) : $handle;
}

sub mount {
    my ($self, $name, $spec, @args) = @_;
    _check_root($self);
    return $self->_mutate(sub { $self->_install_recipe($self->_recipe($name, $spec, @args)) });
}

# Canonicalize lookup names as mount does, so '/a/' finds 'a'.
sub _canon_mount_name {
    my ($name) = @_;
    return undef unless defined $name && !ref $name;
    $name =~ s{^/+}{};
    $name =~ s{/+$}{};
    return length $name ? $name : undef;
}

sub unmount {
    my ($self, $name, %opt) = @_;
    my @unknown = sort grep { $_ ne 'unlink' } keys %opt;
    Carp::croak("Data::Shared: unknown unmount option '$unknown[0]'") if @unknown;
    $name = _canon_mount_name($name);
    return 0 unless defined $name;
    $self->_check_unlinkable($name) if $opt{unlink};
    my $gone;
    my $ret = $self->_mutate(sub {
        $gone = delete $self->{mounts}{$name} or return 0;
        @{ $self->{order} } = grep { $_ ne $name } @{ $self->{order} };
        $self->{_nested} = (grep { index($_, '/') >= 0 } keys %{ $self->{mounts} }) ? 1 : 0;
        $self->{_changed} = 1;
        $self->{_published} = 1 unless $gone->{transient};
        # Retain paths until unlink succeeds, including the crash window after publication.
        $self->_record_retained($gone->{storage_paths}) unless $gone->{transient};
        return 1;
    }, $opt{unlink} ? sub { $self->_retire_storage($gone) } : undef);
    return $ret;
}

# Ownership follows backing storage, including aliases held by other handle objects.
sub _check_unlinkable {
    my ($self, $name) = @_;
    # This check precedes _mutate; keep path caching local to it.
    local $self->{_abs_cache} = {};
    my $mount = $self->{mounts}{$name} or return;
    my $handle = $mount->{handle};
    return unless blessed($handle);
    my $addr = refaddr($handle);
    # Compare canonical paths by containment; composites own their whole directory.
    my @mine = map { $self->_abs_path($_) } _storage_of($mount);
    for my $other (@{ $self->{order} }) {
        next if $other eq $name;
        my $sibling = $self->{mounts}{$other};
        my $shared = blessed($sibling->{handle}) && refaddr($sibling->{handle}) == $addr;
        unless ($shared) {
            my @theirs = map { $self->_abs_path($_) } _storage_of($sibling);
            $shared = grep { my $m = $_; grep { _covers($m, $_) || _covers($_, $m) } @theirs } @mine;
        }
        next unless $shared;
        Carp::croak("Data::Shared: mount '$name' shares its storage with '$other';"
            . " unmount '$other' as well, or unmount '$name' without unlink");
    }
    return;
}

sub _covers {
    my ($outer, $inner) = @_;
    return 1 if $outer eq $inner;
    return index($inner, "$outer/") == 0 ? 1 : 0;
}

# Caller-built transient handles have no recorded storage paths.
sub _storage_of {
    my ($mount) = @_;
    my @paths = @{ $mount->{storage_paths} || [] };
    my $handle = $mount->{handle};
    if (!@paths && blessed($handle) && $handle->can('path')) {
        my $path = eval { $handle->path };
        push @paths, $path if defined $path && !ref $path && length $path;
    }
    return @paths;
}

sub _retire_storage {
    my ($self, $gone) = @_;
    my $handle = $gone && $gone->{handle};
    return $self->_forget_retained($gone) unless $handle && $handle->can('unlink');
    unless (eval { $handle->unlink; 1 }) {
        my $err = $@;
        # Failed retirement leaves storage on the ledger for retry.
        die $err;
    }
    return $self->_forget_retained($gone);
}

sub _forget_retained {
    my ($self, $gone) = @_;
    my @paths = @{ ($gone && $gone->{storage_paths}) || [] } or return;
    my %drop = map { $self->_ledger_form($_) => 1 } @paths;
    my $before = @{ $self->{_retained} };
    @{ $self->{_retained} } = grep { !$drop{$_} } @{ $self->{_retained} };
    return if @{ $self->{_retained} } == $before;
    $self->{_revision}++;
    $self->_write_manifest unless $self->{readonly};
    return;
}

# Record paths inside the root relatively so retained storage survives relocation.
# Paths outside the root remain absolute.
sub _ledger_form {
    my ($self, $path) = @_;
    my $abs = $self->_abs_path($path);
    return $abs unless defined $self->{dir} && length $self->{dir};
    my $dir = $self->_abs_path($self->{dir});
    return $abs unless defined $dir && length $dir && index($abs, "$dir/") == 0;
    return substr $abs, length($dir) + 1;
}

sub _ledger_resolve {
    my ($self, $entry) = @_;
    return $entry if $entry =~ m{\A/};
    return $entry unless defined $self->{dir};
    # Cwd ledger entries are bytes; encode the root directory before concatenating.
    my $dir = $self->{dir};
    utf8::encode($dir) if utf8::is_utf8($dir);
    return "$dir/$entry";
}

sub _record_retained {
    my ($self, $paths) = @_;
    return unless $paths && @$paths;
    # Deduplicate: rotation can retain the same path every cycle.
    my %have = map { $_ => 1 } @{ $self->{_retained} };
    my @new = grep { !$have{$_}++ } map { $self->_ledger_form($_) } @$paths;
    return unless @new;
    push @{ $self->{_retained} }, @new;
    $self->{_published} = 1;
    return;
}

sub handle {
    my ($self, $path) = @_;
    _check_root($self);
    return $self if !defined $path || (!ref $path && ($path eq '' || $path eq '/'));
    my @components = @{ $self->_path_components($path) };
    return $self unless @components;
    if (!ref $path && $self->{mounts}{$path} && !$self->{mounts}{$path}{composite}) {
        return $self->{mounts}{$path}{handle};
    }
    my (undef, $mount, $rest) = _resolve($self, \@components);
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

# sort has undefined scalar-context behavior; a named array also returns a count.
sub mounts { my @k = sort keys %{ $_[0]{mounts} }; return @k }
sub mount_names { my @k = $_[0]->mounts; return @k }

sub mount_info {
    my ($self, $name) = @_;
    $name = _canon_mount_name($name);
    my $m = defined $name ? $self->{mounts}{$name} : undef;
    return undef unless $m;
    return { name => $name, class => $m->{class}, key => $m->{entry}{key},
             dist => $m->{entry}{dist}, path_class => $m->{entry}{path_class},
             file => $m->{file}, transient => $m->{transient},
             composite => $m->{composite} ? 1 : 0 };
}

sub sync_all {
    my ($self) = @_;
    my $n = 0;
    for my $name (@{ $self->{order} }) {
        my $h = $self->{mounts}{$name}{handle};
        next unless $h->can('sync');
        if ($h->isa('Data::Shared::Composite')) { $n += $h->sync }
        else { $h->sync; $n++ }
    }
    return $n;
}

sub freeze_all {
    my ($self) = @_;
    Carp::croak("Data::Shared: cannot freeze a read-only root") if $self->{readonly};
    # The exclusive topology lock serializes concurrent freeze attempts.
    return Data::Shared::Manifest::with_lock($self, 1, sub {
        $self->_assert_revision;
        my $n = 0;
        # Partial freezes follow mount insertion order.
        for my $name (@{ $self->{order} }) {
            my $h = $self->{mounts}{$name}{handle};
            next unless $h->can('freeze');
            # Backends may reject a second freeze.
            next if $h->can('frozen') && $h->frozen;
            # The composite's own count, not 1: it seals a whole subtree.
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
        # Immutable build-then-load backends need no sealing.
        elsif (!($mount->{entry} && $mount->{entry}{immutable})) { return 0 }
    }
    return @{ $self->{order} } ? 1 : 0;
}

sub unlink_all {
    my ($self) = @_;
    Carp::croak("Data::Shared: root is read-only, cannot unlink") if $self->{readonly};
    return Data::Shared::Manifest::with_lock($self, 1, sub {
        my $published = !defined $self->{dir} || -e $self->manifest_path;
        # Retained paths can survive failed cleanup after the manifest is gone.
        # Already unlinked is success, not an error to report.
        return 0 unless $published || @{ $self->{order} } || @{ $self->{_retained} };
        $self->_assert_revision if $published;
        my $n = 0;
        # Insertion order, so a partial failure's survivors stay deterministic.
        for my $name (@{ $self->{order} }) {
            my $mount = $self->{mounts}{$name};
            my $handle = $mount->{handle};
            next unless $handle->can('unlink');
            # Native unlink returns undef for bitset/queue/stack, handles for bloom/roaring/radix.
            # Count filesystem removals rather than successful calls.
            my @paths = grep { length } @{ $mount->{storage_paths} || [] };
            my $before = grep { -e } @paths;
            $handle->unlink;
            $n += @paths ? $before - grep { -e } @paths : 1;
        }
        if ($published && defined $self->{dir}) {
            if (CORE::unlink($self->manifest_path)) { $n++ }
            elsif (!$!{ENOENT}) { Carp::croak("Data::Shared: cannot unlink manifest: $!") }
        }
        # Any process may reclaim retained paths; failed removals must remain retryable.
        if (@{ $self->{_retained} }) {
            my %seen;
            my @entries = grep { !$seen{$_}++ } @{ $self->{_retained} };
            my %path = map { $_ => $self->_ledger_resolve($_) } @entries;
            my $existed = grep { -e $path{$_} } @entries;
            my @paths = map { $path{$_} } @entries;
            my $held = _lock_composite_dirs(\@paths);
            my $failed = _cleanup_paths(\@paths);
            undef $held;
            my @left = grep { -e $path{$_} } @entries;
            $n += $existed - @left;
            @{ $self->{_retained} } = @left;
            Carp::croak("Data::Shared: $failed") if length $failed;
        }
        # Teardown also reclaims unpublished composite storage left by interrupted creation.
        if (defined $self->{dir}) {
            my $children = "$self->{dir}/.children";
            if (opendir my $dh, $children) {
                my @orphans = map { "$children/$_" } grep { $_ ne '.' && $_ ne '..' } readdir $dh;
                closedir $dh;
                if (@orphans) {
                    my $held = _lock_composite_dirs(\@orphans);
                    my $failed = _cleanup_paths(\@orphans);
                    undef $held;
                    Carp::croak("Data::Shared: $failed") if length $failed;
                    $n += @orphans;
                }
            }
            rmdir $children;
            # Interrupted flat mounts can leave unpublished .shm files in the root directory.
            if (opendir my $dh, $self->{dir}) {
                my @stray = grep { /\.shm\z/ && -f "$self->{dir}/$_" }
                    grep { $_ ne '.' && $_ ne '..' } readdir $dh;
                closedir $dh;
                $n += grep { CORE::unlink "$self->{dir}/$_" } @stray;
            }
        }
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

    my $app = Data::Shared->new('/tmp/demo.shared');
    $app->mount('cache', 'hashmap:ii', undef, 100_000)
        unless $app->mount_info('cache');      # a mount is one-time topology
    shared_set($app, '/cache/42', 100);
    my $same = Data::Shared->open('/tmp/demo.shared');
    shared_get($same, '/cache/42');            # 100, from another handle

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

Paths select a mount and an adapter operation. Composite mounts
(L</DEEP PATHS (COMPOSITES)>) add one child address per level. The string,
array and compiled tiers mirror L<Data::Path::XS>; requesting its
C<:keywords> syntax croaks. See L<Data::Shared::Cookbook> for recipes.

B<Linux only, 64-bit Perl>, matching every leaf. Handles are never
cloned into ithreads (C<CLONE_SKIP>).

The leaf dists are recommended rather than required, so installing this
facade does not compile all 39 of them. Install the ones you mount;
mounting a type whose dist is absent croaks naming the dist to install.
C<cpanm --with-recommends Data::Shared> installs every leaf. One
dependency is not implied by what you mount: a composite on an anonymous
root locks its children with Data-Sync-Shared, so install that dist too.
File-backed composites use the directory lock and do not need it.

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

=head2 Data::Shared->open_sealed($dir)

Reopens frozen leaves read-only while allowing lifecycle cleanup with
C<unlink_all>. Reads work; the leaves refuse data writes. C<open>
refuses frozen files, and C<open_readonly> refuses lifecycle writes.

=head2 Data::Shared->open_readonly($dir, strict => 1)

Freeze the store in the producing process first. The 21 families with
C<new_readonly> (the C<freeze> entries in L<Data::Shared::Registry>,
including C<hashmap> and C<bloomfilter>) require frozen files; a live
file aborts replay with the leaf's error under C<failed to replay manifest>.
Other leaves use their normal constructor.
The generic mutating verbs (C<set>, C<delete>, C<incr>, C<push>,
C<pop>), every root lifecycle write (C<mount>, C<unmount>,
C<freeze_all>, C<unlink_all>) and native C<unlink>, C<destroy> and
C<freeze> through C<shared_call> croak on any read-only root. A handle
taken with C<handle> is the leaf itself and carries no root flag: every
native method on it, those three included, keeps whatever permissions
that leaf's own file gives it.

C<< strict => 1 >>, off by default, requires C<new_readonly> or
immutability (PerfectHash) throughout the declared tree, including lazy
composite leaves. Unsupported
backends are rejected before any handle is opened. Raw handles expose the
backend's API; filesystem permissions govern direct writes.

=head2 $root->mount($name, $spec, @ctor_args)

Mounts a structure under C<$name> (which may itself contain C</>, for
nested namespaces; longest-prefix wins). C<$spec> may be:

=over 4

=item * a short spec: C<'hashmap'>, C<'hashmap:ii'>, C<'buffer:i64'>,
C<'queue:int'>, C<'sync:semaphore'>, C<'sortedset:strings'>, etc.
Short specs accept mixed case and resolve to lowercase. See
L<Data::Shared::Registry> for the full inventory.

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
rejected; a constructor argument JSON has no form for at all -- a code
reference, or an object that is not a JSON::PP boolean -- makes the mount
transient rather than refusing it. Failed mount publication restores the previous namespace and
removes backing paths created by that attempt. Existing files are retained.
Factories manage their own external side effects. Nested mount mutations
inside a factory are rejected, and so is reopening the same root: the
factory runs while its caller holds the manifest lock, which no second
root in the same process can acquire. Use the C<$root> it is given.

Mount arguments must survive manifest replay, so a value JSON would
record as something else is refused at mount time instead: C<Inf>,
C<NaN> and lone surrogates. A string spelled exactly as perl spells one
of those is refused with it, since nothing distinguishes the two once a
number has been stringified. Strings are recorded as bytes;
character strings are encoded to UTF-8 first, uniformly from U+0080 up: the character
C<"\x{e9}"> and the single byte C<"\xe9"> are therefore two different
paths naming two different files.

Special cases: C<perfecthash> is an immutable build-then-load structure,
so a C<'perfecthash'> spec takes either a built file path or a
C<< { build_int => \@keys, path => $file } >> / C<build_str> hashref. A
build spec creates a missing file once; an existing file is loaded
without rebuilding. To supply one some other way, pass the factory or
the loaded handle as the spec, as for any other type. C<sortedset:strings> takes
C<< mount('names', 'sortedset:strings', { max => 100_000 }) >>;
C<set>/C<keys> backing paths are auto-filled for file-backed roots.
Explicit backing paths must be absolute. Derived paths follow the root's
directory spelling and are relative exactly when that directory is.

Backing paths already owned by another mount are rejected before
construction, including aliases produced by filename sanitization
(e.g. C<a/b> and C<a__b>) and string SortedSet sidecars. Mount the
same native handle under another name to share it intentionally; an
C<unmount> that would unlink storage another mount still names is
refused, so retire the aliases first.


=head2 $root->unmount($name), $root->mounts, $root->mount_info($name)

Lifecycle and introspection for mounts. Names are canonicalized as
C<mount> canonicalizes them, so C</a/> and C<a> name one mount.
C<unmount> returns 1 when it removed a mount and 0 when there was none;
C<mount_info> returns C<undef> for an absent name, and otherwise a
hashref of C<name>, C<class>, C<key>, C<dist>, C<path_class>, C<file>,
C<transient> and C<composite>.
C<mount_names> is a synonym for C<mounts>; C<available_types> (class or
root method) lists the 39 short spec names and C<registry> returns the
L<Data::Shared::Registry> table itself.

C<unmount> retains storage in a manifest ledger; remounting the same name
adopts it. To reclaim it while serving other mounts, remount it with the
same spec and C<< unmount($name, unlink => 1) >>. C<unlink_all> also reclaims
retained storage from any process, but removes the whole store. Each retained
store costs a manifest entry; use C<< unlink => 1 >> when rotating fresh names.

C<< unmount($name, unlink => 1) >> publishes the removal and retires storage
under the same directory lock. Native C<unlink> and C<destroy> through
C<shared_call> at a mount do the same. See L</SHARING A ROOT> for what
other processes observe.

=head2 $root->dir, $root->readonly, $root->manifest_path

Accessors: the root's directory, whether it was opened read-only, and
the path of its manifest. The directory and the manifest path are both
C<undef> for an anonymous root.

=head2 $root->sync_all, $root->freeze_all, $root->unlink_all, $root->stats, $root->frozen

C<sync_all>, C<freeze_all> and C<unlink_all> visit supported handles in
mount order. Sync and freeze include a composite's parent, child index and
every registered child, open or not. C<freeze_all> counts newly sealed
handles; 0 means everything was already sealed or no mount supports it.

C<stats> returns a hashref keyed by mount name, containing native stats or
C<< { class => ref $handle } >>. Composite stats include child and open counts
and stats for cached children only; evicted children are absent.
Stats fields are backend-specific. F<eg/monitoring.pl> walks registered children
and compares native capacities and configured child budgets with usage.

C<frozen> reports whether a nonempty store is sealed or immutable throughout;
only 21 of the 39 families can be sealed. C<perfecthash> is immutable and
needs no sealing; any of the other 17
(C<buffer>, C<queue>, C<stack>, C<deque>, C<heap>, C<log>, C<pool>,
C<pubsub>, C<reqrep>, C<ringbuffer>, C<sync>, C<timingwheel>,
C<hiertimingwheel>, C<reservoir>, C<topk>, C<segmenttree>,
C<disjointset>) or the
C<sortedset:strings> variant prevents C<frozen>. For a diagnostic after
freezing, C<< open_readonly($dir, strict => 1) >> names the first unsupported
mount and class. Freezing is one-way: C<open> then refuses the store in every
process. Readers reopen it with C<open_readonly>; C<open_sealed> is for
teardown, and gives a writable root over sealed leaves. A mounted native handle is sealed
too, making the caller's object read-only.

C<unlink_all> removes mounts, the manifest and all retained storage,
including storage retained by other processes. It also unlinks every
F<.shm> file directly in the root directory, which reclaims what an
interrupted mount left but takes any other F<.shm> kept there with it.
It leaves F<.manifest.lock>, which another process may still hold. C<freeze_all> and C<unlink_all> croak
on a read-only root.

=head1 SHARING A ROOT

Topology changes serialize under a directory lock and revision. A root
opened before another writer's change gets C<stale manifest revision> from C<mount>,
C<unmount>, C<freeze_all> and C<unlink_all>, raised before any
constructor or factory runs: reopen the root and retry against the
current configuration. A store rebuilt at the same directory is refused as
C<this store was replaced>, and one another process removed as
C<this store was unlinked>; C<unlink_all> returns 0 there instead. Ordinary reads and writes neither check the
revision nor refresh the namespace. A write to a mount another process
retired with C<< unlink => 1 >> can succeed into a mapping whose file is gone.

A root keeps its namespace and cached composite children until reopened.
After another process rebuilds the store, cached reads, C<exists> and
C<children> may still report the old instance until a composite lock triggers
an instance check. They never cross into the replacement store's storage.
Workers that must notice teardown should reopen.

Configure topology from one coordinator and let the workers open the
result; that is the pattern the revision protocol is built for.

=head1 PATH FORMAT

Components are separated by C</>. A leading C</> is optional,
repeated and trailing slashes are tolerated, and the empty path
addresses the root (C<shared_get> returns the root, C<shared_exists>
is true, mutating the root croaks). The first component(s) select the mount (longest
prefix match); the remainder is interpreted by the mount's adapter:

=over 4

=item * Map-like (HashMap, Buffer, RadixTree, Intern, Pool,
PerfectHash): one key/index component. RadixTree instead joins the
remainder with C</> so route-style keys work in string paths.

=item * Set-like (Bloom family, BitSet, RoaringBitmap, SortedSet,
DisjointSet): one member component.

=item * Indexed (NDArray, Fenwick, Fenwick2D, SegmentTree, Graph):
all remaining components are indices/coordinates.

=item * Queue-, sketch- and sync-like: no remainder; use
C<shared_push>/C<shared_pop>/C<shared_call>, which take the value as an
argument. The keyed sketches C<countminsketch> and C<topk> are the
exception: they require exactly one component, the item, and croak
without it. C<ringbuffer>'s C<get> may read one, a sequence number.

=back

Map-, set- and queue-like mounts croak on extra components. RadixTree joins
them instead.

With C<users> and C<users/sales> mounted, C</users/sales/eu> selects
C<users/sales>, hiding the C<sales> record or child of C<users>. Array paths
join the same way, including components containing C</>. Avoid nested mount
names that spell an address their parent also serves.

No escaping is provided in the string tier: keys containing C</> or
the empty string need the array tier.

=head1 GENERIC VERBS

C<shared_get>, C<shared_set>, C<shared_delete>, C<shared_exists> and
C<shared_incr> map to native methods per type
in L<Data::Shared::Registry> (e.g. HashMap C<put/get/remove/exists>,
RadixTree C<insert/lookup/delete/exists>, SortedSet C<add/score/remove>,
Intern C<intern/id_of>). Unsupported verbs croak with guidance to use
C<shared_call>: plain Bloom filters have no delete, and unkeyed sketches
and sync primitives have no keyed get/set.

Each generic verb is also a method on the root, taking the function's
arguments without the leading C<$root>: C<< $root->get('/cache/42') >>,
C<set>, C<delete>, C<exists>, C<incr>, C<push>, C<pop> and
C<< $root->call($path, $method, @args) >>. C<< $root->compile($path) >>
is C<shared_compile>.

Where it is defined, C<shared_exists> always returns C<1> or C<0>, an
index outside the structure included; the families with no honest
C<exists> -- the queue-like leaves, the unkeyed sketches, C<ndarray> and
C<fenwick2d> among them -- croak like any other absent
verb. C<shared_incr> uses C<incr_by> when a delta is given and the leaf
supports it; a leaf with neither C<incr_by> nor a delta form of C<incr>
(most C<buffer> variants) rejects the delta from its own XS, so use
C<shared_call> there. The converse also holds: C<sortedset>, C<pool>,
C<fenwick>, C<fenwick2d> and C<segmenttree> score or add rather than
count, so C<shared_incr> there needs a delta and croaks without one.

Backend semantics:

=over 4

=item * C<shared_set($path, 0)> clears for BitSet, but counts as an add
for RoaringBitmap and the Cuckoo and counting Bloom filters, whose value
argument is ignored. Use C<shared_delete> to remove.

=item * C<shared_delete> on a C<buffer> writes the variant's zero, which
for C<buffer:str> is the one-character string C<"0">.

=item * A write can fail by returning false instead of croaking:
C<sortedset:strings> and C<intern> derive a string arena of 32 bytes per
declared entry, so longer members exhaust it early and C<shared_set>
returns C<undef>. Pass a larger C<arena>, or a larger third constructor
argument for C<intern>, and check the return value. A full C<queue>,
C<deque>, C<stack> or C<heap> drops a C<shared_push> the same way, as
does a C<shared_set> past the end of a C<buffer>.

=item * Keys cross into XS as bytes, so encode wide characters first. A
character above U+00FF is accepted by the HashMap family and the integer
SortedSet, and fatal in RadixTree, Intern, the filter family,
CountMinSketch, TopK, PerfectHash and C<sortedset:strings> (whose every
verb dies).

=item * An integer-addressed leaf numifies a non-integer key, so
C<'abc'> addresses element 0. The C<key_int> families (C<buffer>,
C<disjointset>, C<fenwick>, C<fenwick2d>, C<graph>, C<ndarray>,
C<segmenttree>) refuse it instead; C<bitset>, C<roaringbitmap>,
C<ringbuffer>'s C<get> and the integer C<hashmap> and C<sortedset>
variants address element 0, with a warning under C<-w>; C<pool> croaks,
its slot 0 not being allocated. C<shared_exists> returns 0 for keys the
structure cannot hold, and croaks where the family has no C<exists> of
its own.

=back

=head2 shared_call($root, $path, $method, @args)

Resolves C<$path> to a mount, prepends remaining components to C<@args>,
and calls the native C<$method>, including methods with no generic verb.
For composites, the first remaining component selects a child; the rest
are passed to its method.

C<unlink> and C<destroy> are accepted only at a mount or composite child,
and refused at a record below one. They retire storage with its registration;
at a child this is equivalent to C<shared_delete> on that address.

    shared_call($root, '/visitors', 'add_many', ['a', 'b']);
    shared_call($root, '/fenwick', 'prefix', 500);
    shared_call($root, '/sem', 'acquire', 1.5);

=head2 shared_push($root, $path, @values) / shared_pop($root, $path, @args)

Queue sugar mapping to the native pair per type (Queue C<push/pop>,
Deque C<push_back/pop_front>, Stack C<push/pop>, Heap C<push/pop> with
priority+value, Log C<append> (no pop), PubSub C<publish> (no pop),
RingBuffer C<write> (no pop)). Unsupported directions croak.

=head1 ARRAY PATH API

C<shareda_get/set/delete/exists/incr/call/push/pop> take an arrayref
of components instead of a slash string. Binary-safe; components may
contain C</> or be empty strings, subject to the resolution rule in
L</PATH FORMAT>.

=head1 COMPILED PATH API

C<shared_compile($path)> (string or arrayref) returns a
L<Data::Shared::Compiled> object holding parsed components;
C<sharedc_*> functions reuse it without parsing. First use against a root
caches the resolved mount, verb and key; subsequent calls use the bound native
method. Mount changes invalidate the cache. Compiled objects are per-process:
recompile after C<fork> if the child mounts differently.

=head1 DEEP PATHS (COMPOSITES)

A composite keeps one child structure per stable parent address. Specs are
nested arrayrefs or hashrefs with C<spec>/C<args>/C<child>. Constructor arguments
exclude the backing path; a leading C<undef> placeholder is tolerated.
A trailing arrayref is always a child spec, so constructors taking a trailing
arrayref (such as SpatialHash grid wrapping) must use the hashref form:

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
Bloom filters, sketches, queues, stacks, logs, sync and timing mounts are
rejected as parents at mount time; use them as child leaves.

Semantics at an intermediate path: C<shared_get> returns a
L<Data::Shared::Node> (for SortedSet, the score instead),
C<shared_exists> reports whether a child is registered,
C<shared_delete> deletes the whole subtree, and C<shared_set>
croaks except for the SortedSet score case. C<< $root->node($path) >>
(also exported as C<shared_node>) returns a cursor with relative-path
C<get/set/delete/exists/incr/push/pop/call/call_at/node/children/handle>
methods; C<< $root->children($path) >> (C<shared_children>) lists
registered child addresses. C<handle> on a child leaf path returns
its native handle. Reads of missing children never create them; writes
and any C<call> but C<unlink> and C<destroy> do. Probe with
C<shared_exists> to avoid allocating children.

Each composite declares C<max_children> (default 10_000) and
C<cache_size> open children (default 32, LRU close/reopen) via the
hashref spec form or a trailing C<{max_children =E<gt> ..., cache_size =E<gt> ...}>
in the arrayref form. Budget explicitly for high-cardinality parents. C<cache_size> bounds
one composite's own cache; a nested composite is itself a cached entry
with its own cache plus its parent and index segments, so a deep tree's
open-segment ceiling multiplies per level. The budget sizes the
child index when the composite is created and cannot be raised
afterwards: mounting a name over storage an C<unmount> retained with a
larger C<max_children> is refused.
C<< unmount($name, unlink => 1) >> first, and build the subtree again.
Every child also consumes a parent entry: size the parent for the budget.
A C<sortedset> parent of four fills after four children regardless of
C<max_children>. Both ceilings assume short addresses: a 256-byte
address exhausts the child index near half of C<max_children>, and a
string-keyed parent's own arena can bind first. Anonymous composites
retain all opened children until subtree deletion or root destruction,
because an anonymous segment cannot be reopened after eviction;
C<cache_size> bounds only file-backed child caches, so a long-lived
anonymous composite keeps one mapping per address it has touched, up to
C<max_children>. Use a file-backed
root when processes need to discover children created after C<fork>.
File-backed roots store children under F<.children/> next to the manifest
and reopen them on demand. Composites support C<sync_all>, C<stats>,
C<freeze_all> and subtree deletion. Compiled
paths over composites stay correct across child creation, eviction,
and deletion because they re-dispatch to the child per call.

Allocation, construction, publication, score-only registration, and subtree
deletion use the composite lifecycle lock. Failed construction rolls back
new registrations, counts, and newly created paths; existing scores and
reservations are preserved. Allocated child IDs are never reused. Cached
leaf operations use the backend's own locking. An operation already in
progress during deletion may complete against the old instance; an explicit
native handle continues to refer to that instance after recreation.

The lifecycle lock protects the shared child counter. An unfinished mutation
marker triggers a rebuild on writable open or the next lifecycle lock.
After a holder dies, the kernel releases file locks; anonymous locks recover
the dead owner's lock, costing about 20 kB of shared mapping per composite.
Unpublished child directories require explicit recovery: no API reports them,
and only C<unlink_all> reclaims them. A preexisting unpublished directory for
a reserved child is an error. Recovery covers exceptions and limited
interruption, without promising power-loss transactions or automatic orphan cleanup.

=head1 PERFORMANCE

The facade is pure Perl; every operation ends in the leaf's XS, so
per-call overhead depends on the tier. A sample run of
F<bench/overhead.pl> on one x86_64 host, reading one integer key, rates
taken from measured CPU time:

    native handle    0.09 us/op
    compiled         0.64 us/op
    array path       2.6  us/op
    shared_call      2.8  us/op
    string path      3.1  us/op

Three consecutive runs on one idle host agreed within 2%; measure on your hardware.

String and array paths parse and resolve on every call. Flat compiled paths
check root identity and generation, then invoke the binding without copying
arguments. Use compiled paths or a native C<handle> in hot loops.
F<bench/benchmark.pl>, F<bench/overhead.pl> and F<bench/mounts.pl> supply
the measurements here.
F<bench/composite.pl> measures deep reads with a warm child cache
and with repeated cache eviction. Composite compiled paths still
resolve the child registry on every call; their cost differs from
flat compiled paths.

Creating flat mounts costs quadratic total time: each validates and republishes
the whole manifest. F<bench/mounts.pl> measures this; on the
same host the average was 1.2 ms per mount at 25 mounts and 7.1 ms at 200,
i.e. 1.4 s to create 200, with the 200th alone costing 17 ms. Keys are not
affected: writing 10_000 keys into one flat mount took 35 ms without touching
the manifest. Opening such a root
is superlinear too, and paid by every process that opens it: 0.14 s to
replay 400 mounts on the same host.
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
recommended at installation and enforced at first backend use.

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
Republishing the manifest keeps whatever mode it already had, so a root
you widened on purpose stays widened.
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

Put the root where only its trusted writers can create it. Because an
existing directory keeps its own mode and the manifest inside it is trusted,
a root named under a world-writable directory -- F</tmp> on a shared host,
as the examples here spell it for brevity -- can be pre-created by anyone,
who then chooses what the first real process attaches to.

Mount names are sanitised into the root directory, so a name containing
C<..> or C</> cannot place a backing file outside it. Anything you grant
write access to a shared mapping is trusted not to corrupt it while
others are attached, as with the leaves.

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
