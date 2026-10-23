import type { SuiGrpcClient } from "@mysten/sui/grpc";
import { MODULES } from "../utils/config";

/** Find a permit even when the owner lookup spans multiple filtered pages. */
export async function getOwnedJumpPermitId(
    client: Pick<SuiGrpcClient, "listOwnedObjects">,
    owner: string,
    worldPackageId: string
): Promise<string | null> {
    let cursor: string | null | undefined;
    const visitedCursors = new Set<string>();
    do {
        const page = await client.listOwnedObjects({
            owner,
            type: `${worldPackageId}::${MODULES.GATE}::JumpPermit`,
            limit: 1,
            cursor,
        });
        if (page.objects[0]) return page.objects[0].objectId;
        if (!page.hasNextPage) return null;
        if (!page.cursor || visitedCursors.has(page.cursor)) {
            throw new Error("JumpPermit lookup received invalid pagination from Sui");
        }
        visitedCursors.add(page.cursor);
        cursor = page.cursor;
    } while (true);
}
