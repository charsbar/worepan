use strict;
use warnings;
use FindBin;
use Path::Tiny;
use Test::More;
use WorePAN;
use Archive::Tar;

my $tmpfile = create_dummy_archive();

my $worepan = WorePAN->new(files => [$tmpfile->path], cleanup => 1);

my $dest = $worepan->file("L/LO/LOCAL", $tmpfile->basename);

ok $dest->exists, "copied correctly";
is $dest->stat->mtime => $tmpfile->stat->mtime, "mtime is correct";
is $dest->stat->size => $tmpfile->stat->size, "size is correct";

$tmpfile->parent->remove;

done_testing;

sub create_dummy_archive {
  my $tmpdir = path($FindBin::Bin, "tmp");
  $tmpdir->mkpath;
  my $tmpfile = $tmpdir->child('fake-0.01.tar.gz');
  my $tar = Archive::Tar->new;
  $tar->add_data("lib/WorePAN/Fake.pm", join("\n",
    'package WorePAN::Fake;',
    'our $VERSION = 0.01;',
    '1;'
  ));
  $tar->write("$tmpfile", COMPRESS_GZIP);
  $tmpfile;
}
