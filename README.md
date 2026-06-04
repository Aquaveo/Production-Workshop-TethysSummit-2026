# Workshop


This is an idea about being able to run tethys using `Uvicorn` instead of `daphne`. The gtethsy container mimics what the original tethys container does with a conda environment, but it uses `uvx`. In addition, it does use nginx on a different container, and it removes the need of supervisord and saltstack on the tethys container.
 