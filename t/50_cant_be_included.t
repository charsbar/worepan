use strict;
use warnings;
use Test::More;
use WorePAN;

plan skip_all => "set WOREPAN_NETWORK_TEST to test" unless $ENV{WOREPAN_NETWORK_TEST};

# CPAN::ParseDistribution accepts regular CPAN distributions only
my %cant_be_included = (
  'I/IT/ITUB/ppm/PerlMol-0.35_00.ppm.tar.gz' => 'PerlMol',
);

for (keys %cant_be_included) {
  my $worepan = eval {
    WorePAN->new(
      files => [$_],
      no_network => 0,
      cleanup => 1,
    );
  };

  ok !$@ && $worepan, "created worepan mirror";
  note $@ if $@;
  ok $worepan && !$worepan->look_for($cant_be_included{$_}), "not found in the index";
}

done_testing;
