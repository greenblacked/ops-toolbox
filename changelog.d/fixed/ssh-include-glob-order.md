- `ssh_client_doctor.sh` reads the files an `Include` glob matches in sorted
  order, as ssh does. It used to take them in whatever order the filesystem
  listed them, so on some machines a later file's risky value was reported
  as the one in effect while ssh actually used an earlier safe one.
