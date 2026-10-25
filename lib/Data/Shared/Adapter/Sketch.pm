package Data::Shared::Adapter::Sketch;
use strict;
use warnings;
use Carp ();

our $VERSION = '0.01';

our @CARP_NOT = qw(Data::Shared);

sub _key {
    my ($entry, $rest) = @_;
    Carp::croak("path too short: mount has no key") unless @$rest;
    return join('/', @$rest) if $entry->{key_join};
    Carp::croak("path too long: $entry->{key} takes one key component")
        if @$rest > 1;
    return $rest->[0];
}

sub make_verb {
    my ($class, $verb, $handle, $entry) = @_;
    my $verbs = $entry->{verbs} || {};
    return undef unless exists $verbs->{$verb} && defined $verbs->{$verb};
    my $spec = $verbs->{$verb};
    if (ref $spec eq 'CODE') {
        return sub {
            my ($rest, @a) = @_;
            my $key = _key($entry, $rest);
            return $spec->($handle, $key, @a);
        };
    }
    my $method = $handle->can($spec);
    if (!$method) {
        my $msg = "$entry->{key}: " . ref($handle) . " does not support '$spec'"
            . " (use shared_call for operations outside the generic verbs)";
        return sub { Carp::croak($msg) };
    }
    return sub {
        my ($rest, @a) = @_;
        my $key = _key($entry, $rest);
        return $handle->$method($key, @a);
    };
}


sub make_bound {
    my ($class, $verb, $handle, $entry, $rest) = @_;
    my $verbs = $entry->{verbs} || {};
    return undef unless exists $verbs->{$verb} && defined $verbs->{$verb};
    my $spec = $verbs->{$verb};
    my $key = _key($entry, $rest);
    if (ref $spec eq 'CODE') {
        return sub { my @a = @_; return $spec->($handle, $key, @a) };
    }
    my $method = $handle->can($spec);
    if (!$method) {
        my $msg = "$entry->{key}: " . ref($handle) . " does not support '$spec'"
            . " (use shared_call for operations outside the generic verbs)";
        return sub { Carp::croak($msg) };
    }
    return sub { my @a = @_; return $handle->$method($key, @a) };
}

sub perform {
    my ($class, $verb, $handle, $entry, $rest, @args) = @_;
    my $code = $class->make_verb($verb, $handle, $entry);
    Carp::croak("operation '$verb' is not supported for sketch mount '$entry->{key}'; use shared_call (e.g. add/count/estimate/quantile)")
        unless $code;
    return $code->($rest, @args);
}

sub make_push { return undef }
sub make_bound_push { return undef }
sub make_bound_pop { return undef }
sub make_pop  { return undef }
sub perform_push { Carp::croak("push is not supported for sketch mounts (use shared_call)") }
sub perform_pop  { Carp::croak("pop is not supported for sketch mounts (use shared_call)") }

1;

__END__

=head1 NAME

Data::Shared::Adapter::Sketch - Internal adapter for sketch mounts (Data::Shared)

=head1 DESCRIPTION

Internal to L<Data::Shared>; not a public API. Serves the keyed
generic verbs of CountMinSketch and TopK; all other sketches are
mount-only and reject generic verbs toward C<shared_call>.

=cut
