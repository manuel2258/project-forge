# Measurements

These experiments determine whether parts of the design survive contact with reality. They must happen before anything is built.

- [ ] Whether the build tool accepts a cache produced by the environment system without rebuilding from scratch. The storage model depends on it.
- [ ] How much a copy-on-write build directory actually diverges during a realistic branch build. Determines whether one worker can host several parallel compiles.
- [ ] Peak memory of a link step. Sets slice limits, agents per worker, and machine size.
- [ ] End-to-end cold start of a worker. Decides whether destroying it is viable at all.
- [ ] Whether agents, prompted well, produce bounded, well-formed artifacts and ask few good questions. The quietest risk and the largest — everything can work mechanically and still be useless if the output sprawls.
