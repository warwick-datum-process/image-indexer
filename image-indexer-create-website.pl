#!/usr/bin/perl

use warnings;
use strict;
use utf8;

our $verbose = $ARGV[0] =~ /^-(?:v:-verbose)$/ and shift @ARGV;

my $bucket = 'warwick-wendy-allen--photos';
my $display_seconds = 75;
my $fade_seconds = 5;

if (! -d 'run')
{
    print STDERR 'I am expecting a sub-directory called "run" in my current working directory ("'.`pwd`.'").';
    exit 1;
}

system qq{s3cmd ls s3://$bucket > run/$bucket.ls};

my @files;
open LS, "run/$bucket.ls" or die $!;
while (<LS>)
{
    # Only consider JPEG files that match the expected file name format.
    m<(\d{4}-\d\d-\d\d \d\d:\d\d)\s+(\d+)\s+s3://$bucket/(.*\.jpg)> or print(STDERR), next;
    push @files, $3 if $2 > 10000;
}
close LS;

$" = "',\n        '";
open HTML, '>run/index.html' or die $!;
print HTML <<HTML;
<html>
<head>
  <meta http-equiv="cache-control" content="max-age=5400">
  <meta http-equiv="refresh" content="6000">
  <script language="JavaScript1.1">
  <!--
  //-->
  </script>
  <style>
    img {
        position:absolute;
        left:0; top:0;
        max-width:100%; max-height:100%;
        -webkit-transition: opacity ${fade_seconds}s ease-in-out;
        -moz-transition: opacity ${fade_seconds}s ease-in-out;
        -o-transition: opacity ${fade_seconds}s ease-in-out;
        transition: opacity ${fade_seconds}s ease-in-out;
    }
    .transparent { opacity:0 }
  </style>
</head>
<body>
  <img id="image-below" src="loading.png">
  <img id="image-above">
  <script>
    var files = ['@files'];
    var below = document.getElementById("image-below");
    var above = document.getElementById("image-above");
    function setImage() {
      above.className = "transparent";
      setTimeout(function() {
        above.src = encodeURIComponent(files[Math.round(Math.random() * $#files)]);
        setTimeout(function() {
          above.className = "";
          below.className = "transparent";
          setTimeout(function() {
            below.src = above.src;
            below.className = "";
            eval("setImage()");
          }, ${fade_seconds}000);
        }, ${display_seconds}000 - 2*${fade_seconds}000);
      }, ${fade_seconds}000);
    }
    setImage();
  </script>
</body>
</html>
HTML
close HTML;

sub sys_do
{
    print join " ", @_, "\n" if our $verbose;
    system @_ or warn $!;
}

sys_do "trickle -s -u128 s3cmd put -P loading.png s3://$bucket/loading.png";
sys_do "trickle -s -u128 s3cmd put -P run/index.html s3://$bucket/index.html";

# Finally, create or update a random image.
my $random_file = '';
$random_file = $files[int rand $#files] until $random_file =~ /\.jpg$/;
# $random_file =~ s/([^\w\.\-])/sprintf '%%%02d', unpack('H*',$1)/eg;
sys_do "s3cmd cp -P s3://$bucket/$random_file s3://$bucket/random.jpg";
