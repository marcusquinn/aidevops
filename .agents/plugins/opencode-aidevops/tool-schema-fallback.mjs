export function createFallbackTool() {
  const schemaNode = {
    _zod: {},
    optional() {
      return this;
    },
    describe() {
      return this;
    },
  };

  const fallbackTool = (definition) => definition;
  fallbackTool.schema = {
    enum() {
      return schemaNode;
    },
    string() {
      return schemaNode;
    },
    number() {
      return schemaNode;
    },
    union() {
      return schemaNode;
    },
  };

  return fallbackTool;
}
