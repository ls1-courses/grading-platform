{
  description = "Autolab and Tango deployment for grading.dos.cit.tum.de";

  outputs = { self }: {
    nixosModules.default = import ./nix/module.nix;
  };
}
