package Data::Shared::Adapter::Indexed;
use strict;
use warnings;
use Carp ();

our $VERSION = '0.01';

our @CARP_NOT = qw(Data::Shared);

sub make_verb {
    my ($class, $verb, $handle, $entry) = @_;
    my $verbs = $entry->{verbs} || {};
    return undef unless exists $verbs->{$verb};
    my $spec = $verbs->{$verb};
    return undef unless defined $spec;
    if (ref $spec eq 'CODE') {
        return sub {
            my ($rest, @a) = @_;
            Carp::croak("path too short: mount has no index") unless @$rest;
            return $spec->($handle, @$rest, @a);
        };
    }
    my $method = $handle->can($spec);
    if (!$method) {
        my $msg = "$entry->{key}: " . ref($handle) . " does not support '$spec'"
            . " (use shared_call for operations outside the generic verbs)";
        return sub { Carp::croak($msg) };
    }
    if ($verb eq 'set' || $verb eq 'incr') {
        return sub {
            my ($rest, @a) = @_;
            Carp::croak("path too short: mount has no index") unless @$rest;
            return $handle->$method(@$rest, @a);
        };
    }
    return sub {
        my ($rest, @a) = @_;
        Carp::croak("path too short: mount has no index") unless @$rest;
        return $handle->$method(@$rest);
    };
}


sub make_bound {
    my ($class, $verb, $handle, $entry, $rest) = @_;
    my $verbs = $entry->{verbs} || {};
    return undef unless exists $verbs->{$verb};
    my $spec = $verbs->{$verb};
    return undef unless defined $spec;
    Carp::croak("path too short: mount has no index") unless @$rest;
    my @idx = @$rest;
    if (ref $spec eq 'CODE') {
        return sub { my @a = @_; return $spec->($handle, @idx, @a) };
    }
    my $method = $handle->can($spec);
    if (!$method) {
        my $msg = "$entry->{key}: " . ref($handle) . " does not support '$spec'"
            . " (use shared_call for operations outside the generic verbs)";
        return sub { Carp::croak($msg) };
    }
    if ($verb eq 'set' || $verb eq 'incr') {
        return sub { my @a = @_; return $handle->$method(@idx, @a) };
    }
    return sub { return $handle->$method(@idx) };
}

sub perform {
    my ($class, $verb, $handle, $entry, $rest, @args) = @_;
    my $code = $class->make_verb($verb, $handle, $entry);
    Carp::croak("operation '$verb' is not supported for $entry->{key} (use shared_call)")
        unless $code;
    return $code->($rest, @args);
}

sub make_push { return undef }
sub make_bound_push { return undef }
sub make_bound_pop { return undef }
sub make_pop  { return undef }
sub perform_push { Carp::croak("push is not supported for indexed mounts (use shared_call)") }
sub perform_pop  { Carp::croak("pop is not supported for indexed mounts (use shared_call)") }

1;

__END__

=head1 NAME

Data::Shared::Adapter::Indexed - Internal adapter for indexed mounts (Data::Shared)

=head1 DESCRIPTION

Internal to L<Data::Shared>; not a public API. Translates generic
verbs for multi-index mounts (NDArray, Fenwick, Fenwick2D,
SegmentTree, Graph), where all remaining path components are
indices or coordinates, into native method calls.

=cut
