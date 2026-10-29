use strict;
use warnings;
use ExtUtils::MakeMaker;
use Config;
use lib 'lib';

# MIN_PERL_VERSION below is metadata: ExtUtils::MakeMaker only warns when the
# running perl is older and writes the Makefile anyway, so a smoker on an
# older perl got through configure and reported FAIL for syntax it could not
# parse, where this reports NA. Gated before this dist's own modules load,
# which is why the line below is a require and not a use.
if ($] < 5.022) { print "Perl 5.22 or later required\n"; exit 0 }
unless ($^O eq 'linux') { print "OS unsupported: requires Linux\n"; exit 0 }
if ($Config{ivsize} < 8) { print "OS unsupported: requires 64-bit Perl\n"; exit 0 }
require Data::Shared::Registry;

my $version = MM->parse_version('lib/Data/Shared.pm');
my %backends = map {
    my $entry = $_;
    (my $module = $entry->{dist}) =~ s/-/::/g;
    ($module => $entry->{min_version});
} values %{ Data::Shared::Registry::registry() };

WriteMakefile(
    NAME             => 'Data::Shared',
    VERSION_FROM     => 'lib/Data/Shared.pm',
    ABSTRACT_FROM    => 'lib/Data/Shared.pm',
    AUTHOR           => 'vividsnow',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.022',
    PREREQ_PM        => {
        'JSON::PP' => 0,
        "File::Temp" => 0,
        "File::Path" => 0,
    },
    TEST_REQUIRES => {
        'Test::More'      => '0.96',
        'File::Temp'      => 0,
        'File::Path'      => 0,
    },
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => '6.64',
    },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        # Backends are recommended, not required: mounting a type whose dist is
        # absent croaks naming the dist to install, so a user installs only the
        # structures they mount instead of compiling all 39. Use
        # `cpanm --with-recommends` to get the lot.
        prereqs => { runtime => { recommends => \%backends } },
        # MakeMaker already excludes t and inc; extend that list.
        no_index => { directory => [qw(xt eg bench)] },
        resources   => {
            repository => {
                type => 'git',
                url  => 'https://github.com/vividsnow/perl5-data-shared.git',
                web  => 'https://github.com/vividsnow/perl5-data-shared',
            },
            bugtracker => {
                web => 'https://github.com/vividsnow/perl5-data-shared/issues',
            },
        },
        provides => {
            'Data::Shared' => { file => 'lib/Data/Shared.pm', version => $version },
            'Data::Shared::Registry' => { file => 'lib/Data/Shared/Registry.pm', version => $version },
            'Data::Shared::Compiled' => { file => 'lib/Data/Shared/Compiled.pm', version => $version },
            'Data::Shared::Node' => { file => 'lib/Data/Shared/Node.pm', version => $version },
            'Data::Shared::Composite' => { file => 'lib/Data/Shared/Composite.pm', version => $version },
            'Data::Shared::Manifest' => { file => 'lib/Data/Shared/Manifest.pm', version => $version },
            'Data::Shared::Storage' => { file => 'lib/Data/Shared/Storage.pm', version => $version },
            map { ("Data::Shared::Adapter::$_" =>
                   { file => "lib/Data/Shared/Adapter/$_.pm", version => $version }) }
                qw(Indexed Map Queue Set Sketch Sync),
        },
    },
    clean => { FILES => 'MANIFEST.bak' },
);
