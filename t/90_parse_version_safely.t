use strict;
use warnings;
use Test::More;
use WorePAN;

plan skip_all => "set WOREPAN_NETWORK_TEST to test" unless $ENV{WOREPAN_NETWORK_TEST};

eval { require IO::Capture::Stderr } or plan skip_all => "requires IO::Capture::Stderr";

my $capture = IO::Capture::Stderr->new;
$capture->start;

my $worepan = WorePAN->new(
  files => ['W/WH/WHYNOT/File-AptFetch-0.0.7.tar.gz'],
  use_backpan => 1,
  no_network => 0,
  cleanup => 1,
);
$capture->stop;

my $captured = join('', $capture->read) || '';

unlike $captured => qr{\$VAR1 = }, 'captured warning should not contain \$VAR1';
like $captured => qr{_parse_version_safely}, 'but should contain parse error';

note $captured;

done_testing;
