// Standalone stub provider for tests outside bun (the Swift TutorEngineClient tests, §11.1).
// Replies come from env STUB_REPLIES (a JSON array of StubReply); prints one line
// {"baseUrl": "..."} on stdout, then serves until stdin closes.
import { startStubProvider, type StubReply } from "./stub-provider";

const stub = startStubProvider();
for (const reply of JSON.parse(process.env.STUB_REPLIES ?? "[]") as StubReply[]) stub.enqueue(reply);
console.log(JSON.stringify({ baseUrl: stub.baseUrl }));
for await (const _ of console) {
    // Ignore input; stdin closing ends the loop.
}
stub.stop();
process.exit(0);
