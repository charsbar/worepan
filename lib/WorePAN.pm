package WorePAN;

use strict;
use warnings;
use CPAN::ParseDistribution;
use Path::Extended::Dir;
use Path::Extended::File;
use LWP::Simple;
use IO::Zlib;
use JSON;
use URI;
use URI::QueryParam;
use version;

our $VERSION = '0.01';

sub new {
  my ($class, %args) = @_;

  $args{verbose} ||= $ENV{TEST_VERBOSE};

  if (!$args{root}) {
    require File::Temp;
    $args{root} = File::Temp::tempdir(CLEANUP => 1);
    warn "'root' is missing; created a temporary WorePAN directory: $args{root}\n" if $args{verbose};
  }
  $args{root} = Path::Extended::Dir->new($args{root})->mkdir;
  $args{cpan} ||= "http://www.cpan.org/";
  if ($args{use_backpan}) {
    $args{backpan} ||= "http://backpan.cpan.org/";
  }
  $args{no_network} = 1 if !defined $args{no_network} && $ENV{HARNESS_ACTIVE};

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
sub file { shift->{root}->file('authors/id', @_) }
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
      if ($file !~ m{^([A-Z])/(\1[A-Z0-9_])/\2[A-Z0-9_]+/.+}) {
        if ($file =~ m{^([A-Z])([A-Z0-9_])[A-Z0-9_]+/.+}) {
          $file = "$1/$1$2/$file";
        }
        else {
          warn "unsupported file format: $file\n";
          next;
        }
      }

      $dest = $self->__fetch($file) or next;
    }
  }
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
    my $res = get($uri) or return;
    my $rows = eval { JSON::decode_json($res) };
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
    if (!is_error(mirror($url => $dest))) {
      return $dest;
    }
    if ($self->{backpan}) {
      my $url = $self->{backpan}."/authors/id/$file";
      $self->_log("mirror $url to $dest");
      if (!is_error(mirror($url => $dest))) {
        return $dest;
      }
    }
  }
  warn "Can't fetch $file\n";
  return;
}

sub update_indices {
  my $self = shift;
  my $root = $self->{root}->subdir('authors/id');

  my (%authors, %packages);
  $root->recurse(callback => sub {
    my $file = shift;
    return if -d $file;

    my $basename = $file->basename;
    return unless $basename =~ /\.(?:tar\.(?:gz|bz2)|tgz|zip)$/;

    my $path = $file->relative($root);
    my ($author) = $path =~ m{^[A-Z]/[A-Z][A-Z0-9_]/([^/]+)/};
    $authors{$author} = 1;

    # tweaks for CPAN::ParseDistribution to warn less verbosely
    local *CPAN::ParseDistribution::qv = \&version::qv;
    local $SIG{__WARN__} = sub {
      if ($_[0] =~ /^_parse_version_safely: \$VAR1 = ({.+};)\s*$/sm) {
        my $err = eval $1;
        if ($err && ref $err eq ref {}) {
          warn "_parse_version_safely error ($err->{line}) at $err->{file}";
          return;
        }
      }
      warn @_;
    };
    my $dist = eval { CPAN::ParseDistribution->new($file->path, use_tar => $self->{tar}) } or return;
    my $modules = $dist->modules;
    for my $module (keys %$modules) {
      if ($packages{$module}) {
        if (eval { version->new($packages{$module}[0]) < version->new($modules->{$module}) }) {
          $packages{$module} = [$modules->{$module}, $path];
        }
      }
      else {
        $packages{$module} = [$modules->{$module}, $path];
      }
    }
  });
  $self->_write_mailrc(\%authors);
  $self->_write_packages_details(\%packages);

  return 1;
}

sub _write_mailrc {
  my ($self, $authors) = @_;

  my $index = $self->mailrc;
  $index->parent->mkdir;
  my $fh = IO::Zlib->new($index->path, "wb") or die $!;
  for (sort keys %$authors) {
    $fh->printf("alias %s \"%s <%s\@cpan.org>\"\n", $_, $_, lc $_);
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
  for (sort keys %$packages) {
    $fh->printf("%-40s %-7s %s\n",
      $_,
      (defined $packages->{$_}[0] ? $packages->{$_}[0] : 'undef'),
      $packages->{$_}[1]
    );
  }
  $fh->close;
  $self->_log("created $index");
}

sub look_for {
  my ($self, $package) = @_;

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

sub authors {
  my $self = shift;

  my $index = $self->mailrc;
  return [] unless $index->exists;
  my $fh = IO::Zlib->new($index->path, "rb") or die $!;

  my @authors;
  while(<$fh>) {
    my ($id, $name, $email) = $_ =~ /^alias\s+(\S+)\s+"?(.+?)\s+(\S+?)"?\s*$/;
    next unless $id;
    $email =~ tr/<>//d;
    push @authors, {pauseid => $id, name => $name, email => $email};
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

  require CPAN::DistnameInfo;
  require CPAN::Version;
  my %dists;
  for (@{ $self->files || [] }) {
    my $dist = CPAN::DistnameInfo->new($_);
    my $name = $dist->dist or next;
    if (
      !exists $dists{$name}
      or CPAN::Version->vlt($dists{$name}->version, $dist->version)
    ) {
      $dists{$name} = $dist;
    }
  }
  [values %dists];
}

sub DESTROY {
  my $self = shift;
  if ($self->{cleanup}) {
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

=item tar

Given a path to a tar executable, L<CPAN::ParseDistribution> will use it internally; otherwise, L<Archive::Tar> will be used.

=item verbose

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

=head2 root

returns a L<Path::Extended::Dir> object that represents the root path you specified (or created internally).

=head2 file

takes a relative path to a distribution ("P/PA/PAUSE/distribution.tar.gz") and returns a L<Path::Extended::File> object.

=head2 mailrc

returns a L<Path::Extended::File> object that represents the "01mailrc.txt.gz" file.

=head2 packages_details

returns a L<Path::Extended::File> object that represents the "02packages.details.txt.gz" file.

=head2 look_for

takes a package name and returns the version and the path of the package if it exists.

=head2 authors

returns an array reference of hash references each of which holds an author's information stored in the mailrc file.

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
