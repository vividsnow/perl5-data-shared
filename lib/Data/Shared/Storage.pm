package Data::Shared::Storage;
use strict;
use warnings;
use Carp ();
use Scalar::Util ();
use Data::Shared::Manifest ();

our $VERSION = '0.01';

our @CARP_NOT = qw(Data::Shared Data::Shared::Manifest Data::Shared::Storage
                   Data::Shared::Composite);
my %LOADED;

sub plan {
    my ($root, $resolved, $name, $args) = @_;
    my $class = $resolved->{class};
    my @args = @$args;
    my $plan = { resolved => $resolved, name => $name, args => \@args, paths => [] };
    if ($resolved->{entry} && ($resolved->{entry}{ctor} // '') eq 'handle_only') {
        $plan->{kind} = 'perfecthash';
        if (@args == 1 && defined $args[0] && !ref $args[0]) {
            $plan->{file} = $args[0];
        } elsif (@args == 1 && ref $args[0] eq 'HASH') {
            my $opt = $args[0];
            $plan->{file} = $opt->{path};
            $plan->{file} = $root->_file_for($name) if !defined $plan->{file} && defined $root->{dir};
            $plan->{build} = exists $opt->{build_int} ? 'build_int' : exists $opt->{build_str} ? 'build_str' : undef;
            $plan->{keys} = $opt->{ $plan->{build} } if $plan->{build};
            Carp::croak('perfecthash build keys must be an ARRAY reference')
                if $plan->{build} && ref $plan->{keys} ne 'ARRAY';
        } else {
            # Named for this position only. The old text also offered a factory
            # and a loaded handle, which do not belong here: those are passed
            # as the SPEC, like any other type, and never reach this branch.
            Carp::croak('Data::Shared: a perfecthash spec takes a built file path or a'
                . ' {build_int|build_str, path} hashref; pass a factory or a loaded'
                . ' handle as the spec itself instead');
        }
        Carp::croak('perfecthash mount requires a path') unless defined $plan->{file};
    } elsif ($class eq 'Data::SortedSet::Shared::Strings') {
        $plan->{kind} = 'strings';
        # The leading-undef placeholder every other spec accepts would become a
        # hash key here and warn before the croak below, so reject it by name.
        Carp::croak("sortedset:strings takes options, not the undef path"
            . " placeholder: pass max => N (and optionally set/keys)")
            if @args && !defined $args[0];
        Carp::croak('sortedset:strings options must be a hashref or key/value pairs')
            if !(@args == 1 && ref $args[0] eq 'HASH') && @args % 2;
        my %opt = @args == 1 && ref $args[0] eq 'HASH' ? %{ $args[0] } : @args;
        Carp::croak("sortedset:strings mount requires 'max'") unless defined $opt{max};
        if (defined $root->{dir}) {
            $opt{set} = $root->_file_for($name) unless defined $opt{set};
            $opt{keys} = $root->_file_for($name . '__keys') unless defined $opt{keys};
        }
        $plan->{options} = \%opt;
        $plan->{file} = $opt{set};
        $plan->{paths} = [grep { defined $_ } @opt{qw(set keys)}];
    } else {
        $plan->{kind} = 'normal';
        if (defined $root->{dir} && (!@args || !defined $args[0] || (!ref $args[0] && $args[0] eq ':file'))) {
            shift @args if @args;
            unshift @args, $root->_file_for($name);
        }
        $plan->{file} = $args[0] if @args && defined $args[0] && !ref $args[0];
    }
    $plan->{paths} = [$plan->{file}] if $plan->{kind} ne 'strings' && defined $plan->{file};
    for my $path (@{ $plan->{paths} }) {
        Carp::croak("Data::Shared: invalid backing path for '$name'")
            if ref $path || !length($path) || index($path, "\0") >= 0;
    }
    return $plan;
}

sub require_files {
    my ($plan) = @_;
    Carp::croak("Data::Shared: mount '$plan->{name}' has no backing file to reopen") unless @{ $plan->{paths} };
    for my $path (@{ $plan->{paths} }) {
        Carp::croak("Data::Shared: missing backing file '$path' for '$plan->{name}'; refusing to recreate storage")
            unless -f $path;
    }
    return;
}

sub _load {
    my ($resolved) = @_;
    my $load = $resolved->{load} || $resolved->{class};
    my $minimum = $resolved->{entry} && $resolved->{entry}{min_version};
    my $key = $load . "\0" . ($minimum // '');
    return if $LOADED{$key};
    # Pass the dist name through: a variant class like
    # Data::HashMap::Shared::II lives in the Data-HashMap-Shared dist, so it
    # cannot be derived from the class name.
    Data::Shared::_require_class($load, $resolved->{entry} && $resolved->{entry}{dist});
    if ($minimum) {
        eval { $load->VERSION($minimum) };
        Carp::croak("Data::Shared: backend $load requires version $minimum or newer: $@") if $@;
    }
    $LOADED{$key} = 1;
}

sub check_readonly {
    my ($resolved) = @_;
    my $class = $resolved->{class};
    _load($resolved);
    return if $resolved->{entry} && $resolved->{entry}{immutable};
    Carp::croak("Data::Shared: strict read-only access is not supported by $class")
        unless $class->can('new_readonly');
    return;
}

sub construct {
    my ($root, $plan) = @_;
    my $resolved = $plan->{resolved};
    my $class = $resolved->{class};
    my $ctor = $resolved->{ctor} || 'new';
    my $opening = $root->{_opening} || $root->{readonly};
    require_files($plan) if $opening;
    check_readonly($resolved) if $root->{strict_readonly};
    _load($resolved);
    my $handle;
    if ($plan->{kind} eq 'perfecthash') {
        if (!-e $plan->{file}) {
            Carp::croak("perfecthash file '$plan->{file}' does not exist; build it first or mount a loaded handle")
                unless $plan->{build} && !$opening;
            my $build = $plan->{build};
            my ($keys) = Data::Shared::Manifest::snapshot($plan->{keys});
            $class->$build($plan->{file}, $keys);
        }
        $handle = $class->load($plan->{file});
    } elsif ($plan->{kind} eq 'strings') {
        my ($options) = Data::Shared::Manifest::snapshot($plan->{options});
        $handle = $class->new(%$options);
    } elsif ($root->{readonly} && $class->can('new_readonly')) {
        $handle = $class->new_readonly($plan->{file});
    } else {
        my ($args) = Data::Shared::Manifest::snapshot($plan->{args});
        # frozen_ok: the freeze walk must reach children that are already
        # frozen, and a frozen file refuses the writable constructor.
        if (($root->{_cleanup} || $root->{_frozen_ok}) && $class->can('new_readonly')) {
            $handle = eval { $class->$ctor(@$args) };
            my $error = $@;
            if (!$handle) {
                $handle = eval { $class->new_readonly($plan->{file}) };
                die $error unless $handle;
            }
        } elsif (!defined $root->{dir} && @$args && !defined $args->[0]
                 && $class->can('new_anon')) {
            # An anonymous mount passes undef as the path, which every buffer
            # variant takes into C as NULL and rejects with EFAULT. Those
            # classes expose new_anon instead. Tried second, not first, so no
            # class that already accepts new(undef, ...) changes behaviour.
            $handle = eval { $class->$ctor(@$args) };
            if (!$handle) {
                my $error = $@;
                $handle = eval { $class->new_anon(@{$args}[1 .. $#$args]) };
                die $error unless $handle;
            }
        } else {
            $handle = $class->$ctor(@$args);
        }
    }
    Carp::croak("Data::Shared: constructor for '$plan->{name}' did not return a handle")
        unless Scalar::Util::blessed($handle);
    return ($handle, $plan->{file}, $plan->{paths});
}

1;

__END__

=head1 NAME

Data::Shared::Storage - Internal storage planning and construction

=head1 DESCRIPTION

Internal to L<Data::Shared>. Resolves constructor paths without opening
backends, validates existing files on reopen, and selects native constructors.
PerfectHash files are built only when first created. Strict read-only opens
require a native read-only constructor or an immutable backend.

=cut
