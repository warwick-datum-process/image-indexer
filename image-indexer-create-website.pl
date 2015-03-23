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
die "No JPG files were found in the AWS S3 bucket '$bucket'." unless @files;

$" = "',\n        '";
open HTML, '>run/index.html' or die $!;
print HTML <<HTML;
<html>
<head>
  <meta http-equiv="cache-control" content="max-age=5400">
  <meta http-equiv="refresh" content="6000">
  <style>
    img {
      max-width:100%; max-height:100%;
    }
    .transparent { opacity:0 }
    #images {
      position:absolute;
      z-index:1;
      width:100%; height:100%;
      left:0; top:0;
    }
    #images img {
      position:absolute;
      left:0; top:0;
      -webkit-transition: opacity ${fade_seconds}s ease-in-out;
      -moz-transition: opacity ${fade_seconds}s ease-in-out;
      -o-transition: opacity ${fade_seconds}s ease-in-out;
      transition: opacity ${fade_seconds}s ease-in-out;
    }
    #settings-outer {
      position:absolute;
      z-index:3;
      width:5px;
      top:0; right:0;
      overflow:hidden;
      -webkit-transition:all 1.0s ease-in-out;
      -moz-transition:all 1.0s ease-in-out;
      -o-transition:all 1.0s ease-in-out;
      transition:all 1.0s ease-in-out;
    }
    #settings-outer.visible {
      width:85px;
    }
    #settings {
      width:80px;
      margin:0 5px;
    }
    button {
      padding:3px;
      margin:12px 3px 3px;
      border-radius:8px;
    }
  </style>
</head>
<body>
  <div id="images">
    <img id="image-below" src="loading.png">
    <img id="image-above">
  </div>
  <div id="settings-outer" onmouseover="this.className='visible'" onmouseout="this.className=''">
  <div id="settings">
    <img id="thumbnail">
    <form name="image-adjust" action="http://ubuntu-acer/image-indexer/image-adjust.pl">
      <button type"button" value="hide">Hide this image</hide>
      <button type"button" value="hide">Rotate clockwise</hide>
      <button type"button" value="hide">Rotate anti-clockwise</hide>
      <button type"button" value="hide">Rotate 180 degrees</hide>
    </form>
  </div>
  </div>
  <script>
    var files = ['@files'];
    var below = document.getElementById("image-below");
    var above = document.getElementById("image-above");
    var thumb = document.getElementById("thumbnail");
    function setImage() {
      above.className = "transparent";
      below.className = "";
      setTimeout(function() {
        above.src = encodeURIComponent(files[Math.round(Math.random() * $#files)]);
        setTimeout(function() {
          above.className = "";
          below.className = "transparent";
          thumb.src = above.src;
          setTimeout(function() {
            below.src = above.src;
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
my $attempts_to_find_a_random_file = 0;
until ($random_file =~ /\.jpg$/)
{
    die "Cannot find a random JPEG file in the list of ".@files." files downloaded from the AWS S3 bucket, '$bucket'." if $attempts_to_find_a_random_file++ > 100;
    $random_file = $files[int rand $#files];
    print "Random file = '$random_file'.\n" if $verbose;
}
# $random_file =~ s/([^\w\.\-])/sprintf '%%%02d', unpack('H*',$1)/eg;
sys_do "s3cmd cp -P s3://$bucket/$random_file s3://$bucket/random.jpg";
