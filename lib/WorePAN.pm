package WorePAN;

use strict;
use warnings;
use Archive::Any::Lite;
use File::Temp ();
use Parse::PMFile;
use Parse::CPAN::Whois;
use Path::Extended::Dir;
use Path::Extended::File;
use File::Spec;
use HTTP::Tiny;
use JSON;
use URI;
use URI::QueryParam;
use version;
use CPAN::Meta::YAML;
use CPAN::DistnameInfo;
use IO::Zlib;

our $VERSION = '0.11';

sub new {
  my ($class, %args) = @_;

  $args{verbose} = $ENV{TEST_VERBOSE} unless defined $args{verbose};

  if (!$args{root}) {
    $args{root} = File::Temp::tempdir(CLEANUP => 1, ($args{tmp} ? (DIR => $args{tmp}) : TMPDIR => 1));
    warn "'root' is missing; created a temporary WorePAN directory: $args{root}\n" if $args{verbose};
  }
  $args{root} = Path::Extended::Dir->new($args{root})->mkdir;
  $args{cpan} ||= "http://www.cpan.org/";
  if ($args{use_backpan}) {
    $args{backpan} ||= "http://backpan.cpan.org/";
  }
  $args{no_network} = 1 if !defined $args{no_network} && $ENV{HARNESS_ACTIVE};

  $args{pid} = $$;

  $args{ua} ||= HTTP::Tiny->new(
    agent => "WorePAN/$VERSION",
  );

  my $self = bless \%args, $class;

  my @files = @{ delete $self->{files} || [] };
  if (!$self->{no_network}) {
    if (my $dists = delete $self->{dists}) {
      push @files, $self->_dists2files($dists);
    }
  }
  # XXX: I don't think we need something like ->_mods2files, right?

  if (@files) {
    $self->_fetch(\@files);
    $self->update_indices;
  }

  $self;
}

sub root { shift->{root} }
sub file {
  my $self = shift;
  my $file = $self->_normalize(File::Spec->catfile(@_)) or return;
  $self->{root}->file('authors/id', $file);
}
sub whois { shift->{root}->file('authors/00whois.xml') }
sub mailrc { shift->{root}->file('authors/01mailrc.txt.gz') }
sub packages_details { shift->{root}->file('modules/02packages.details.txt.gz') }

sub add_files {
  my ($self, @files) = @_;
  $self->_fetch(\@files);
}

sub add_dists {
  my ($self, %dists) = @_;
  if ($self->{no_network}) {
    warn "requires network\n";
    return;
  }
  my @files = $self->_dists2files(\%dists);
  $self->_fetch(\@files);
}

sub _fetch {
  my ($self, $files) = @_;

  my %authors;
  my %packages;
  my $_root = $self->{root}->subdir('authors/id');
  for my $file (@$files) {
    my $dest;
    if (-f $file && $file =~ /\.(?:tar\.(?:gz|bz2)|tgz|zip)$/) {
      my $source = Path::Extended::File->new($file);
      $dest = $_root->file('L/LO/LOCAL/', $source->basename);
      $self->_log("copy $source to $dest");
      $source->copy_to($dest);
      $dest->mtime($source->mtime);
    }
    else {
      $file = $self->_normalize($file) or next;
      $dest = $self->__fetch($file) or next;
    }
  }
}

sub _normalize {
  my ($self, $file) = @_;

  $file =~ s|\\|/|g if $^O eq 'MSWin32';

  if ($file !~ m{^([A-Z])/(\1[A-Z0-9_])/\2[A-Z0-9_\-]*/.+}) {
    if ($file =~ m{^([A-Z])([A-Z0-9_])[A-Z0-9_\-]*/.+}) {
      $file = "$1/$1$2/$file";
    }
    else {
      warn "unsupported file format: $file\n";
      return;
    }
  }
  return $file;
}

sub _dists2files {
  my ($self, $dists) = @_;
  return unless ref $dists eq ref {};

  my $uri = URI->new('http://api.cpanauthors.org/uploads/dist');
  my @keys = keys %$dists;
  my @files;
  while (@keys) {
    my @tmp = splice @keys, 0, 50;
    $uri->query_param(d => [
      map { $dists->{$_} ? "$_,$dists->{$_}" : $_ } @tmp
    ]);
    $self->_log("called API: $uri");
    my $res = $self->{ua}->get($uri);
    if (!$res->{success}) {
      warn "API error: $uri $res->{status} $res->{reason}";
      return;
    }
    my $rows = eval { JSON::decode_json($res->decoded_content) };
    if ($@) {
      warn $@;
      return;
    }
    push @files, @$rows;
  }

  map {
    $_->{filename} && $_->{author}
      ? join '/',
          substr($_->{author}, 0, 1),
          substr($_->{author}, 0, 2),
          $_->{author},
          $_->{filename}
      : ()
  } @files;
}

sub _log {
  my ($self, $message) = @_;
  print STDERR "$message\n" if $self->{verbose};
}

sub __fetch {
  my ($self, $file) = @_;

  my $dest = $self->{root}->file("authors/id/", $file);
  return $dest if $dest->exists;

  $dest->parent->mkdir;

  if ($self->{local_mirror}) {
    my $source = Path::Extended::File->new($self->{local_mirror}, "authors/id", $file);
    if ($source->exists) {
      $self->_log("copy $source to $dest");
      $source->copy_to($dest);
      $dest->mtime($source->mtime);
      return $dest;
    }
  }
  if (!$self->{no_network}) {
    my $url = $self->{cpan}."authors/id/$file";
    $self->_log("mirror $url to $dest");
    my $res = $self->{ua}->mirror($url => $dest);
    return $dest if $res->{success};
    if ($self->{backpan}) {
      my $url = $self->{backpan}."authors/id/$file";
      $self->_log("mirror $url to $dest");
      my $res = $self->{ua}->mirror($url => $dest);
      return $dest if $res->{success};
    }
  }
  warn "Can't fetch $file\n";
  return;
}

sub walk {
  my ($self, %args) = @_;
  my $root = $self->{root}->subdir('authors/id');
  my $tmproot = $self->{tmp} || $args{tmp};

  local $Archive::Any::Lite::IGNORE_SYMLINK = 1;
  $root->recurse(callback => sub {
    my $archive_file = shift;
    return if -d $archive_file;

    my $path = $archive_file->relative($root);
    my $basename = $archive_file->basename;
    return unless $basename =~ /\.(?:tar\.(?:gz|bz2)|tgz|zip)$/;
    return if $basename =~ /^perl\-\d+/; # perls
    return if !$args{developer_releases} && (
         $basename =~ /\d\.\d+_\d/  # dev release
      or $basename =~ /TRIAL/       # trial release
    );

    my $archive = Archive::Any::Lite->new($archive_file->path);
    my $tmpdir = Path::Extended::Dir->new(File::Temp::tempdir(CLEANUP => 1, ($tmproot ? (DIR => $tmproot) : (TMPDIR => 1))));
    $archive->extract($tmpdir);
    my $basedir = $tmpdir->children == 1 ? ($tmpdir->children)[0] : $tmpdir;
    $basedir = $tmpdir unless -d $basedir;

    $args{callback}->($basedir, $path, $archive_file);

    $tmpdir->remove;
  });
}

sub update_indices {
  my $self = shift;

  return if $self->{no_indices};

  my (%authors, %packages);
  $self->walk(callback => sub {
    my ($basedir, $path, $archive_file) = @_;

    my $mtime = $archive_file->mtime;
    my ($author) = $path =~ m{^[A-Z]/[A-Z][A-Z0-9_]/([^/]+)/};
    $authors{$author} = 1;

    # a dist that has blib/ shouldn't be indexed
    # see PAUSE::dist::mail_summary
    return if $basedir->basename eq 'blib' or $basedir->subdir('blib')->exists;

    my ($metafile, @pmfiles);
    $basedir->recurse(callback => sub {
      my $file = shift;
      push @pmfiles, $file if $file =~ /\.pm(?:\.PL)?$/i;
      $metafile ||= $file if $file =~ /META.(?:yml|json)$/;
    });

    my $meta;
    if ($metafile) {
      my $content = do { local $/; open my $fh, '<:utf8', $metafile; <$fh> };
      if ($metafile =~ /\.yml$/) {
        $meta = eval { CPAN::Meta::YAML->read_string($content)->[0] };
      } else {
        $meta = eval { JSON::decode_json($content) };
      }
    }

    # Provides field has precedence; should also check meta_ok
    if ($self->_version_from_meta_ok($meta)) {
      $self->_update_packages(\%packages, $meta->{provides}, $path, $mtime);
      return;
    }

    my $parser = Parse::PMFile->new($meta);
PMFILES:
    for my $pmfile (@pmfiles) {
      my $relpath = $pmfile->relative($basedir);

      # adopted from PAUSE::dist::filter_pms
      next if $relpath =~ m!^(?:x?t|inc|local|perl5)!;

      if ($meta) {
        my $no_index = $meta->{no_index} || $meta->{private};
        if (ref $no_index eq 'HASH') {
          my %map = (
            file => qr{\z},
            directory => qr{/},
          );
          for my $k (qw(file directory)) {
            next unless my $v = $no_index->{$k};
            my $rest = $map{$k};
            if (ref $v eq 'ARRAY') {
              for my $ve (@$v) {
                $ve =~ s|/+$||;
                next PMFILES if $relpath =~ /^$ve$rest/;
              }
            } else {
              $v =~ s|/+$||;
              next PMFILES if $relpath =~ /^$v$rest/;
            }
          }
        }
      }

      my $info = $parser->parse($pmfile);
      $self->_update_packages(\%packages, $info, $path, $mtime);
    }
  });
  $self->_write_whois(\%authors);
  $self->_write_mailrc(\%authors);
  $self->_write_packages_details(\%packages);

  return 1;
}

# borrowed from PAUSE::dist
sub _version_from_meta_ok {
  my ($self, $meta) = @_;
  return unless $meta && ref $meta eq ref {};

  my $provides = $meta->{provides};
  return unless $provides && ref $provides eq ref {} && %$provides;

  my ($mb_v) = ($meta->{generated_by} || '') =~ /Module::Build version ([\d\.]+)/;
  return 1 unless $mb_v;
  return 1 if $mb_v eq '0.250.0';
  return if $mb_v >= 0.19 && $mb_v < 0.26;
  return 1;
}

sub _update_packages {
  my ($self, $packages, $info, $path, $mtime) = @_;

  for my $module (sort keys %$info) {
    if (!$packages->{$module}) { # shortcut
      $packages->{$module} = [$info->{$module}{version}, $path, $mtime];
      next;
    }
    my $ok = 0;
    my $new_version = $info->{$module}{version};
    my $cur_version = $packages->{$module}[0];
    if (Parse::PMFile->_vgt($new_version, $cur_version)) {
      $ok++;
    }
    elsif (Parse::PMFile->_vgt($cur_version, $new_version)) {
      # lower VERSION number
    }
    else {
      if (
        $new_version eq 'undef' or $new_version == 0 or
        Parse::PMFile->_vcmp($new_version, $cur_version) == 0
      ) {
        if ($mtime >= $packages->{$module}[2]) {
          $ok++; # dist is newer
        }
      }
    }
    if ($ok) {
      $packages->{$module} = [$new_version, $path, $mtime];
    }
  }
}

sub _write_whois {
  my ($self, $authors) = @_;

  my $index = $self->whois;
  $index->parent->mkdir;
  $index->openw;
  $index->printf(qq{<?xml version="1.0" encoding="UTF-8"?>\n<cpan-whois xmlns='http://www.cpan.org/xmlns/whois' last-generated='%s UTC' generated-by='WorePAN %s'>\n}, scalar(gmtime), $VERSION);
  for my $id (sort keys %$authors) {
    $index->printf("<cpanid><id>%s</id><type>author</type><fullname>%s</fullname><email>%s\@cpan.org</email></cpanid>\n", $id, $id, lc $id);
  }
  $index->print("</cpan-whois>\n");
  $index->close;
  $self->_log("created $index");
}

sub _write_mailrc {
  my ($self, $authors) = @_;

  my $index = $self->mailrc;
  $index->parent->mkdir;
  my $fh = IO::Zlib->new($index->path, "wb") or die $!;
  for my $id (sort keys %$authors) {
    $fh->printf("alias %s \"%s <%s\@cpan.org>\"\n", $id, $id, lc $id);
  }
  $fh->close;
  $self->_log("created $index");
}

sub _write_packages_details {
  my ($self, $packages) = @_;

  my $index = $self->packages_details;
  $index->parent->mkdir;
  my $fh = IO::Zlib->new($index->path, "wb") or die $!;
  $fh->print("File: 02packages.details.txt\n");
  $fh->print("Last-Updated: ".localtime(time)."\n");
  $fh->print("\n");
  for my $pkg (map {$_->[1]} sort {($a->[0] cmp $b->[0]) || ($a->[1] cmp $b->[1])} map {[lc $_, $_]} keys %$packages) {
    my ($first, $second) = (30, 8);
    my $ver = defined $packages->{$pkg}[0] ? $packages->{$pkg}[0] : 'undef';
    if (length($pkg) > $first) {
      $second = length($ver);
      $first += 8 - $second;
    }
    $fh->printf("%-${first}s %${second}s  %s\n",
      $pkg,
      $ver,
      $packages->{$pkg}[1]
    );
  }
  $fh->close;
  $self->_log("created $index");
}

sub look_for {
  my ($self, $package) = @_;

  return unless defined $package;

  my $index = $self->packages_details;
  return [] unless $index->exists;
  my $fh = IO::Zlib->new($index->path, "rb") or die $!;

  my $done_preambles = 0;
  while(<$fh>) {
    chomp;
    if (/^\s*$/) {
      $done_preambles = 1;
      next;
    }
    next unless $done_preambles;
    if (/^$package\s+(\S+)\s+(\S+)$/) {
      return wantarray ? ($1, $2) : $1;
    }
  }
  return;
}

sub authors { shift->_authors_whois }

sub _authors_mailrc {
  my $self = shift;

  my $index = $self->mailrc;
  return [] unless $index->exists;
  my $fh = IO::Zlib->new($index->path, "rb") or die $!;

  my @authors;
  while(defined(my $line = <$fh>)) {
    my ($id, $name, $email) = $line =~ /^alias\s+(\S+)\s+"?(.+?)\s+(\S+?)"?\s*$/;
    next unless $id;
    $email =~ tr/<>//d;
    push @authors, {pauseid => $id, name => $name, email => $email};
  }
  \@authors;
}

sub _authors_whois {
  my $self = shift;

  my $index = $self->whois;
  return [] unless $index->exists;
  my @authors;
  for (Parse::CPAN::Whois->new($index->path)->authors) {
    push @authors, {
      pauseid => $_->pauseid,
      name => $_->name,
      asciiname => $_->asciiname,
      email => $_->email,
      homepage => $_->homepage,
    };
  }
  \@authors;
}

sub modules {
  my $self = shift;

  my $index = $self->packages_details;
  return [] unless $index->exists;
  my $fh = IO::Zlib->new($index->path, "rb") or die $!;

  my @modules;
  my $done_preambles = 0;
  while(<$fh>) {
    chomp;
    if (/^\s*$/) {
      $done_preambles = 1;
      next;
    }
    next unless $done_preambles;

    /^(\S+)\s+(\S+)\s+(\S+)/ or next;
    push @modules, {module => $1 ,version => $2 eq 'undef' ? undef : $2, file => $3};
  }
  \@modules;
}

sub files {
  my $self = shift;
  my $index = $self->packages_details;
  return [] unless $index->exists;
  my $fh = IO::Zlib->new($index->path, "rb") or die $!;

  my %files;
  my $done_preambles = 0;
  while(<$fh>) {
    chomp;
    if (/^\s*$/) {
      $done_preambles = 1;
      next;
    }
    next unless $done_preambles;

    /^\S+\s+\S+\s+(\S+)/ or next;
    $files{$1} = 1;
  }
  [keys %files];
}

sub latest_distributions {
  my $self = shift;

  my %dists;
  for my $file (@{ $self->files || [] }) {
    my $dist = CPAN::DistnameInfo->new($file);
    my $name = $dist->dist or next;
    if (
      !exists $dists{$name}
      or Parse::PMFile->_vlt($dists{$name}->version, $dist->version)
    ) {
      $dists{$name} = $dist;
    }
  }
  [values %dists];
}

sub DESTROY {
  my $self = shift;
  if ($self->{cleanup} && $$ == $self->{pid}) {
    $self->{root}->remove;
  }
}

1;

__END__

=head1 NAME

WorePAN - creates a partial CPAN mirror for tests

=head1 SYNOPSIS

    use WorePAN;

    my $worepan = WorePAN->new(
      root => 'path/to/destination/',
      files => [qw(
        I/IS/ISHIGAKI/WorePAN-0.01.tar.gz
      )],
      cleanup     => 1,
      use_backpan => 0,
      no_network  => 0,
      tmp => 'path/to/tmpdir',
    );

=head1 DESCRIPTION

WorePAN helps you to create a partial CPAN mirror with minimal indices. It's useful when you test something that requires a small part of a CPAN mirror. You can use it to build a DarkPAN as well.

The main differences between this and the friends are: this works under the Windows (hence the "W-"), and this fetches files not only from the CPAN but also from the BackPAN (and from a local directory with the same layout as of the CPAN) if necessary.

=head1 METHODS

=head2 new

creates an instance, and fetches files/updates indices internally.

Options are:

=over 4

=item root

If specified, a WorePAN mirror will be created under the specified directory; otherwise, it will be created under a temporary directory (which is accessible via C<root>).

=item cpan

a CPAN mirror from where you'd like to fetch files.

=item files

takes an arrayref of filenames to fetch. As of this writing they should be paths to existing files or path parts that follow C<http://your.CPAN.mirror/authors/id/>.

=item dists

If network is available (see below), you can pass a hashref of distribution names (N.B. not package/module names) and required versions, which will be normalized into an array of filenames via remote API. If you don't remember who has released a specific version of a distribution, this may help.

  my $worepan = WorePAN->new(
    dists => {
      'Catalyst-Runtime' => 5.9,
      'DBIx-Class'       => 0,
    },
  );

=item local_mirror

takes a path to your local CPAN mirror from where files are copied.

=item no_network

If set to true, WorePAN won't try to fetch files from remote sources. This is set to true by default when you're in tests.

=item use_backpan

If set to true, WorePAN also looks into the BackPAN when it fails to fetch a file from the CPAN.

=item backpan

a BackPAN mirror from where you'd like to fetch files.

=item cleanup

If set to true, WorePAN removes its contents when the instance is gone (mainly for tests).

=item verbose

=item no_indices

If set to true, WorePAN won't create/update indices.

=item tmp

If set, temporary directories will be created in the specified directory.

=back

=head2 add_files

  $worepan->add_files(qw{
    I/IS/ISHIGAKI/WorePAN-0.01.tar.gz
  });

Adds files to the WorePAN mirror. When you add files with this method, you need to call C<update_indices> by yourself.

=head2 add_dists

  $worepan->add_dists(
    'Catalyst-Runtime' => 5.9,
    'DBIx-Class'       => 0,
  );

Adds distributions to the WorePAN mirror. When you add distributions with this method, you need to call C<update_indices> by yourself.

=head2 update_indices

Creates/updates mailrc and packages_details indices.

=head2 walk

  $worepan->walk(callback => sub {
    my $distdir = shift;
  
    my $meta_yml = $distdir->file('META.yml');
  
    $distdir->recurse(callback => sub {
      my $file_in_a_dist = shift;
      return unless $file_in_a_dist =~ /\.pm$/;
      ...
    });
  });

Walks down the WorePAN directory and extracts each distribution into a temporary directory, and runs a callback to which a Path::Extended::Dir object for the directory is passed as an argument. Used internally to create indices.

=head2 root

returns a L<Path::Extended::Dir> object that represents the root path you specified (or created internally).

=head2 file

takes a relative path to a distribution ("P/PA/PAUSE/distribution.tar.gz") and returns a L<Path::Extended::File> object.

=head2 whois

returns a L<Path::Extended::File> object that represents the "00whois.xml" file.

=head2 mailrc

returns a L<Path::Extended::File> object that represents the "01mailrc.txt.gz" file.

=head2 packages_details

returns a L<Path::Extended::File> object that represents the "02packages.details.txt.gz" file.

=head2 look_for

takes a package name and returns the version and the path of the package if it exists.

=head2 authors

returns an array reference of hash references each of which holds an author's information stored in the whois file.

=head2 modules

returns an array reference of hash references each of which holds a module name and its version stored in the packages_details file.

=head2 files

returns an array reference of files listed in the packages_details file.

=head2 latest_distributions

returns an array reference of L<CPAN::DistnameInfo> objects each of which holds a latest distribution's info stored in the packages_details file.

=head1 HOW TO PRONOUNCE (IF YOU CARE)

(w)oh-ray-PAN, not WORE-pan. "Ore" (pronounced oh-ray) indicates the first person singular in masculine speech in Japan, and the "w" adds a funny tone to it.

=head1 SEE ALSO

L<OrePAN>, L<CPAN::Faker>, L<CPAN::Mini::FromList>, L<CPAN::ParseDistribution>

=head1 AUTHOR

Kenichi Ishigaki, E<lt>ishigaki@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 by Kenichi Ishigaki.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
