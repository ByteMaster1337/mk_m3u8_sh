mk\_m3u8.sh
===========

mk\_m3u8.sh is a CLI bash script for creating m3u playlists.
You can feed it directorys, single files and even other playlists to parse as
input. For directories and playlist inputs, meta data like disc and title index
are evaluated for file order.
soxi tool is used to extract metadata.

This tool may be of use to any linux user with a collection of media files for
creating playlists for your mp3 or other media files or to update playlists
with metadata or fix them after you transcoded your files to a different
format.

This project started out as a very simple "put my ogg files into a playlist"
type of script and somewhat grew since then. It's now at a point where I feel
that it needs to be rewritten in a "proper" language. Still I think it does
it's job and may be of some use ... or at least some snippets of code from
this. Either as inspiration or a deterrent example.
That's why I decided to release it.
This means I don't have any real plans for further development of this code at
the moment.

# Installing and using
Just make sure the script is executable and you have bash.
The script exits with an error if it cannot run soxi.

Running and using the script should be self explanatory. If you open the script
in an editor you see some variables that hold default settings and a revision
history.

# Development
I hope the code reads like a good book. No further prerequisites.
As stated above I don't plan further development, but feel free to contribute.
Just try to not make this too much of a mess.
