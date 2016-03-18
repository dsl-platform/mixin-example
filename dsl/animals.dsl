module animals
{
  mixin Animal {
    String latinName;
  }

  value Mammal {
    has mixin Animal;
    Int numberOfTits;
  }

  value Bird {
    has mixin Animal;
    Double wingspan;
  }

  value Reptile {
    has mixin Animal;
    Boolean isDinosaur;
  }

  aggregate Zoo {
    Animal animal;
  }
}
