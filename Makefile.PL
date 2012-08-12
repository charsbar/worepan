use strict;
use warnings;
use ExtUtils::MakeMaker;

my %params = (
    NAME          => 'WorePAN',
    AUTHOR        => 'Kenichi Ishigaki <ishigaki@cpan.org>',
    VERSION_FROM  => 'lib/WorePAN.pm',
    ABSTRACT_FROM => 'lib/WorePAN.pm',
    LICENSE       => 'perl',
    PREREQ_PM     => {
        'Archive::Tar' => 0,
        'CPAN::DistnameInfo' => 0,
        'CPAN::ParseDistribution' => 0,
        'CPAN::Version' => 0,
        'IO::Zlib' => 0,
        'JSON' => 0,
        'LWP::Simple' => 0,
        'Path::Extended' => 0,
        'Test::More'          => '0.88', # done_testing
        'Test::UseAllModules' => '0.10',
        'URI' => 0,
        'URI::QueryParam' => 0,
        'version' => 0,
    },
    META_MERGE => {
        resources => {
            repository => 'https://github.com/charsbar/worepan',
        },
    },
);

my $eumm = $ExtUtils::MakeMaker::VERSION;
delete $params{MIN_PERL_VERSION} if $eumm < 6.48;
delete $params{META_MERGE}       if $eumm < 6.46;
delete $params{META_ADD}         if $eumm < 6.46;
delete $params{LICENSE}          if $eumm < 6.31;

if ($eumm < 6.52 && $params{CONFIGURE_REQUIRES}) {
    $params{PREREQ_PM} = {
        %{ $params{PREREQ_PM}          || {} },
        %{ $params{CONFIGURE_REQUIRES} },
    };
    delete $params{CONFIGURE_REQUIRES};
}
if ($eumm < 6.5503 && $params{BUILD_REQUIRES}) {
    $params{PREREQ_PM} = {
        %{ $params{PREREQ_PM}      || {} },
        %{ $params{BUILD_REQUIRES} },
    };
    delete $params{BUILD_REQUIRES};
}

WriteMakefile(%params);
