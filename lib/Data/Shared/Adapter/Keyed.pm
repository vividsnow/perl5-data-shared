package Data::Shared::Adapter::Keyed;
use strict;
use warnings;
use Carp ();
use parent 'Data::Shared::Adapter';
# The argument guards live there, and an adapter is reachable on its own: the
# facade had always loaded it first, so calling into it was a latent die.
use Data::Shared::Registry ();

our $VERSION = '0.01';

# Path and verb croaks here are the caller's mistake, so Carp must not stop at
# the facade frame that dispatched into this adapter.
our @CARP_NOT = qw(Data::Shared);

# Map-like and set-like mounts take one component and address one record with
# it, so this was two identical files whose only difference was whether they
# called that component a key or a member -- and a fix to one had to be made
# twice. Each subclass names its own noun; nothing else differed.
sub _noun { 'key' }

sub _key {
    my ($entry, $rest, $verb, $noun) = @_;
    Carp::croak("Data::Shared: path too short: mount has no $noun") unless @$rest;
    return join('/', @$rest) if $entry->{key_join};
    # Dropping the components past the first addressed a record the path did
    # not name.
    Carp::croak("Data::Shared: path too long: $entry->{key} takes one $noun component")
        if @$rest > 1;
    # An integer mount numifies a non-integer key to element 0, so a garbage
    # key would read or overwrite it. Here rather than per call, because a
    # bound closure resolves its key once. The exemption is for the key shape
    # only: exists answers 0 for a key it cannot hold, and its own verb
    # refuses the shape.
    Data::Shared::Registry::_assert_index($entry->{key}, $rest->[0])
        if $entry->{key_int} && $verb ne 'exists';
    return $rest->[0];
}

sub make_verb {
    my ($class, $verb, $handle, $entry) = @_;
    my $spec = Data::Shared::Adapter::_spec($entry, $verb);
    return undef unless defined $spec;
    my $noun = $class->_noun;       # bind time: the closures below capture it
    if (ref $spec eq 'CODE') {
        # A CODE spec returns before the string-method branch below, so the
        # delta check has to be here too or an undef delta reaches the leaf.
        return sub {
            my ($rest, @a) = @_;
            Data::Shared::Registry::_assert_delta($entry->{key}, @a) if $verb eq 'incr';
            return $spec->($handle, _key($entry, $rest, $verb, $noun), @a);
        };
    }
    my $method = $handle->can($spec);
    if (!$method) {
        my $msg = Data::Shared::Adapter::_unsupported($entry, $handle, $spec);
        return sub { Carp::croak($msg) };
    }
    if ($verb eq 'incr') {
        my $by = $handle->can('incr_by');
        return sub {
            my ($rest, @a) = @_;
            Data::Shared::Registry::_assert_delta($entry->{key}, @a);
            my $key = _key($entry, $rest, $verb, $noun);
            return $handle->$by($key, $a[0]) if @a && $by;
            return $handle->$method($key, @a);
        };
    }
    return sub { my ($rest, @a) = @_; return $handle->$method(_key($entry, $rest, $verb, $noun), @a) };
}

sub make_bound {
    my ($class, $verb, $handle, $entry, $rest) = @_;
    my $spec = Data::Shared::Adapter::_spec($entry, $verb);
    return undef unless defined $spec;
    my $key = _key($entry, $rest, $verb, $class->_noun);
    if (ref $spec eq 'CODE') {
        return sub {
            my @a = @_;
            Data::Shared::Registry::_assert_delta($entry->{key}, @a) if $verb eq 'incr';
            return $spec->($handle, $key, @a);
        };
    }
    my $method = $handle->can($spec);
    if (!$method) {
        my $msg = Data::Shared::Adapter::_unsupported($entry, $handle, $spec);
        return sub { Carp::croak($msg) };
    }
    if ($verb eq 'incr') {
        my $by = $handle->can('incr_by');
        return sub {
            my @a = @_;
            Data::Shared::Registry::_assert_delta($entry->{key}, @a);
            return $handle->$by($key, $a[0]) if @a && $by;
            return $handle->$method($key, @a);
        };
    }
    return sub { my @a = @_; return $handle->$method($key, @a) };
}

1;

__END__

=head1 NAME

Data::Shared::Adapter::Keyed - Internal base for one-component mounts (Data::Shared)

=head1 DESCRIPTION

Internal to L<Data::Shared>; not a public API. Translates generic verbs for
mounts addressed by a single path component into native method calls, and
builds the cached per-verb coderefs used on the dispatch fast path.
L<Data::Shared::Adapter::Map> and L<Data::Shared::Adapter::Set> differ only in
the word they use for that component.

=cut
