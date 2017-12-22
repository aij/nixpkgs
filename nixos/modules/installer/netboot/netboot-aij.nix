# This module contains -the-basic- a custom configuration for building netboot
# images

{ config, lib, pkgs, ... }:

with lib;

{
  imports =
    [ ./netboot.nix

      # Profiles of this basic netboot media
      ../../profiles/all-hardware.nix
      ../../profiles/base.nix
      ../../profiles/installation-device.nix # FIXME?
      ../../profiles/minimal.nix
    ];

  # Don't stall sshd.
  systemd.services.sshd.wantedBy = mkForce [ "multi-user.target" ];

  # Allow the user to log in as root without a password.
  users.extraUsers.root.initialHashedPassword = ""; # FIXME?

  # No autologin
  services.mingetty.autologinUser = mkForce null;

  # Select internationalisation properties.
  i18n = {
    consoleFont = "Lat2-Terminus16";
    consoleKeyMap = "dvorak";
    defaultLocale = "en_US.UTF-8";
  };

  # Set your time zone.
  time.timeZone = "America/Chicago";

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAgEAm/qx6C2ZvSTGlUJXvucKpOs2rx6B1XnJWo0I8IYyCYoQxzjjNEwcLiy7bgOCjfYNqb2z/5XlMuspa0S32sUx0Z3WuJe9g6HOMzpxxaS9iYVW4eXtfpkbXBBkwXrwaFQ/3NX+/12cgj+8hgkkQFFBBUdUcU1UBRrBo9N5MqCSpjkDKFpFObSQ/gAu9Rv0cgQD4nRSvktEkd/43tI0PE+DLW0/xB6DOCN76eAEK9vB+EvPXndzAkaChF+ICmX6CLfSQVHPzujkQrFVVQCIWR2kQgtIFCh28hIp8wRJko3bUyN3oY40fFxAriP70ze3RX2M6GzuH4oN88rGCOW2WT08P/6hcqPZWQQxr7ZlWn/e1dFTH3RJluiitQ3Em7Z1jHfTy/1NWRl2s0+ZEUA1H9uUUvejPUo5J15Vjrepc7RGZ0CWtU2aP+nTTQQfvDizMiVXMNyIoUl8uTJt8zn8loLx82O8qrZ3D+7fbV2mXUlJVmG/aZvlU86dDX8BLU29B1LBFaLd3bJnIoZ/JnTEKXYKs/vZaFiU/IQpw80Ev91P5KkXsxOssIL5VpZ7S4nAUz+0FjPEeQfj0lnjb5a7nFhIFG7K46p95HUrmojJ3+6jzKUHMQdVEefYRKYo/yDK63PF2JMzDnkTO0t4rSeAqXHE47Vv8MrbgWOQ/w4HyZccmMc= aij@ita"
  ];

  }
