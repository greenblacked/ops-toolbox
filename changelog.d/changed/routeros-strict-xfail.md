- The RouterOS script tests mark known parser failures as strict expected
  failures, so a script that starts passing on a new release fails the suite
  until its marker is removed, instead of passing unnoticed.
